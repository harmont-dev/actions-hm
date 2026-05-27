# Harmont GitHub Action Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a GitHub Action (`harmont-dev/actions-hm`) that makes it trivial to run harmont pipelines inside GitHub Actions workflows — one step to adopt, zero Docker-caching boilerplate.

**Architecture:** Four composite actions sharing shell scripts. `setup/` installs the `hm` binary and optional Python DSL. `cache-restore/` and `cache-save/` wrap the `hm cache restore`/`hm cache save` commands with GHA's `actions/cache`. The root `action.yml` composes all three into a single step: install → restore cache → `hm run` → save cache. All shell logic lives in `scripts/` and is tested with ShellCheck + bats.

**Tech Stack:** YAML (composite actions), Bash (install/cache scripts), bats-core (script tests), ShellCheck (lint), GitHub Actions

**Why split sub-actions?** Power users who run multiple pipelines or need custom steps between cache-restore and run can use the granular actions. Newcomers use the root all-in-one.

**Target user experience:**

```yaml
# One-liner adoption:
- uses: harmont-dev/actions-hm@v1
  with:
    pipeline: ci

# Granular control:
- uses: harmont-dev/actions-hm/setup@v1
- uses: harmont-dev/actions-hm/cache-restore@v1
- run: hm run ci
- uses: harmont-dev/actions-hm/cache-save@v1
  if: always()
```

**Repo structure at completion:**

```
actions-hm/
├── action.yml                    # All-in-one composite
├── setup/
│   └── action.yml                # Install hm + optional Python DSL
├── cache-restore/
│   └── action.yml                # Restore Docker image cache
├── cache-save/
│   └── action.yml                # Save Docker image cache
├── scripts/
│   ├── install-hm.sh             # Download/install hm binary
│   └── resolve-version.sh        # Resolve 'latest' to release tag
├── tests/
│   ├── resolve-version.bats      # Unit tests for version resolution
│   └── install-hm.bats           # Unit tests for install script
├── .github/
│   └── workflows/
│       ├── ci.yml                # Lint + unit tests for this action
│       └── test-action.yml       # Integration test exercising the action
└── .gitignore
```

---

## Task 1: Project scaffolding and linting infrastructure

**Files:**
- Create: `.gitignore`
- Create: `.github/workflows/ci.yml`

**Step 1: Write `.gitignore`**

```gitignore
# bats
test_helper/
tests/tmp/

# OS
.DS_Store
```

**Step 2: Write CI workflow that runs ShellCheck + bats**

This workflow will fail initially (no scripts exist yet). That's expected — it validates that our test infrastructure works.

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run ShellCheck
        uses: ludeeus/action-shellcheck@2.0.0
        with:
          scandir: scripts/

  bats:
    name: Bats tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bats
        run: |
          sudo apt-get update && sudo apt-get install -y bats
      - name: Run tests
        run: bats tests/*.bats
```

**Step 3: Commit**

```bash
git add .gitignore .github/workflows/ci.yml
git commit -m "chore: scaffold project with CI workflow"
```

---

## Task 2: Version resolution script

Resolves a user-provided version input (`latest`, `1.2.3`, `v1.2.3`) into a concrete release tag. This is the smallest, most testable piece — start here.

**Files:**
- Create: `scripts/resolve-version.sh`
- Create: `tests/resolve-version.bats`

**Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

setup() {
  export RESOLVE="$BATS_TEST_DIRNAME/../scripts/resolve-version.sh"
}

@test "passes through explicit semver unchanged" {
  run bash "$RESOLVE" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.2.3" ]
}

@test "passes through v-prefixed version unchanged" {
  run bash "$RESOLVE" "v1.2.3"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.2.3" ]
}

@test "fails on empty input" {
  run bash "$RESOLVE" ""
  [ "$status" -ne 0 ]
}

@test "latest resolves via GitHub API" {
  # Mock: override curl with a function that returns a fake tag
  mock_curl() {
    echo '{"tag_name": "v0.5.0"}'
  }
  export -f mock_curl

  # Use CURL_CMD override for testability
  CURL_CMD=mock_curl run bash "$RESOLVE" "latest"
  [ "$status" -eq 0 ]
  [ "$output" = "v0.5.0" ]
}
```

**Step 2: Run tests, verify they fail**

Run: `bats tests/resolve-version.bats`
Expected: FAIL — script doesn't exist

**Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
REPO="harmont-dev/harmont-cli"
CURL_CMD="${CURL_CMD:-curl}"

if [[ -z "$VERSION" ]]; then
  echo "::error::version input is required" >&2
  exit 1
fi

if [[ "$VERSION" == "latest" ]]; then
  tag=$($CURL_CMD -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
  if [[ -z "$tag" ]]; then
    echo "::error::failed to resolve latest version from GitHub" >&2
    exit 1
  fi
  echo "$tag"
elif [[ "$VERSION" =~ ^v ]]; then
  echo "$VERSION"
else
  echo "v${VERSION}"
fi
```

**Step 4: Make script executable and run tests**

Run: `chmod +x scripts/resolve-version.sh && bats tests/resolve-version.bats`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add scripts/resolve-version.sh tests/resolve-version.bats
git commit -m "feat: add version resolution script with tests"
```

---

## Task 3: Install script

Downloads the `hm` binary and adds it to `$GITHUB_PATH`. Tries GitHub releases first, falls back to `cargo-binstall`, then `cargo install`.

**Files:**
- Create: `scripts/install-hm.sh`
- Create: `tests/install-hm.bats`

**Step 1: Write the failing test**

```bash
#!/usr/bin/env bats

setup() {
  export INSTALL="$BATS_TEST_DIRNAME/../scripts/install-hm.sh"
  export TMPDIR
  TMPDIR="$(mktemp -d)"
  export GITHUB_PATH="$TMPDIR/github_path"
  touch "$GITHUB_PATH"
  export GITHUB_OUTPUT="$TMPDIR/github_output"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "detects linux x86_64 platform" {
  # Source the script to test the detect_platform function
  source "$INSTALL"
  OS="Linux" ARCH="x86_64" run detect_platform
  [ "$status" -eq 0 ]
  [[ "$output" == *"x86_64"* ]]
  [[ "$output" == *"linux"* ]]
}

@test "detects darwin arm64 platform" {
  source "$INSTALL"
  OS="Darwin" ARCH="arm64" run detect_platform
  [ "$status" -eq 0 ]
  [[ "$output" == *"aarch64"* ]] || [[ "$output" == *"arm64"* ]]
  [[ "$output" == *"darwin"* ]] || [[ "$output" == *"apple"* ]]
}

@test "fails on unsupported platform" {
  source "$INSTALL"
  OS="Windows_NT" ARCH="x86_64" run detect_platform
  [ "$status" -ne 0 ]
}

@test "adds install dir to GITHUB_PATH" {
  # This test verifies the path-registration logic in isolation
  source "$INSTALL"
  INSTALL_DIR="$TMPDIR/bin"
  mkdir -p "$INSTALL_DIR"
  register_path "$INSTALL_DIR"
  grep -q "$INSTALL_DIR" "$GITHUB_PATH"
}
```

**Step 2: Run tests, verify they fail**

Run: `bats tests/install-hm.bats`
Expected: FAIL — script doesn't exist

**Step 3: Write implementation**

```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?version tag required (e.g. v0.5.0)}"
INSTALL_DIR="${2:-${RUNNER_TOOL_CACHE:-/tmp}/hm/bin}"
REPO="harmont-dev/harmont-cli"

detect_platform() {
  local os="${OS:-$(uname -s)}"
  local arch="${ARCH:-$(uname -m)}"

  case "$os" in
    Linux)  os_part="unknown-linux-gnu" ;;
    Darwin) os_part="apple-darwin" ;;
    *)
      echo "::error::Unsupported OS: $os" >&2
      return 1
      ;;
  esac

  case "$arch" in
    x86_64)       arch_part="x86_64" ;;
    aarch64|arm64) arch_part="aarch64" ;;
    *)
      echo "::error::Unsupported architecture: $arch" >&2
      return 1
      ;;
  esac

  echo "${arch_part}-${os_part}"
}

register_path() {
  local dir="$1"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$dir" >> "$GITHUB_PATH"
  fi
  export PATH="$dir:$PATH"
}

try_github_release() {
  local platform="$1"
  local url="https://github.com/${REPO}/releases/download/${VERSION}/hm-${platform}"

  echo "::group::Downloading hm ${VERSION} for ${platform}"
  mkdir -p "$INSTALL_DIR"

  if curl -fsSL --retry 3 -o "${INSTALL_DIR}/hm" "$url"; then
    chmod +x "${INSTALL_DIR}/hm"
    echo "::endgroup::"
    return 0
  fi

  echo "::endgroup::"
  echo "::warning::No prebuilt binary at ${url}, trying fallback"
  return 1
}

try_cargo_binstall() {
  if ! command -v cargo-binstall &>/dev/null; then
    return 1
  fi

  echo "::group::Installing hm via cargo-binstall"
  local tag_version="${VERSION#v}"
  cargo binstall --no-confirm --version "$tag_version" harmont-cli
  echo "::endgroup::"
}

try_cargo_install() {
  if ! command -v cargo &>/dev/null; then
    echo "::error::No prebuilt binary found and cargo is not available" >&2
    return 1
  fi

  echo "::group::Installing hm via cargo install (this may take a few minutes)"
  local tag_version="${VERSION#v}"
  cargo install --version "$tag_version" harmont-cli
  echo "::endgroup::"
}

main() {
  local platform
  platform="$(detect_platform)"

  if try_github_release "$platform"; then
    register_path "$INSTALL_DIR"
  elif try_cargo_binstall; then
    true
  elif try_cargo_install; then
    true
  else
    echo "::error::All installation methods failed" >&2
    exit 1
  fi

  echo "::group::Verify installation"
  hm --version
  echo "::endgroup::"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "hm-version=$(hm --version)" >> "$GITHUB_OUTPUT"
  fi
}

# Allow sourcing for tests without running main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
```

**Step 4: Make executable and run tests**

Run: `chmod +x scripts/install-hm.sh && bats tests/install-hm.bats`
Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add scripts/install-hm.sh tests/install-hm.bats
git commit -m "feat: add hm install script with platform detection and fallback chain"
```

---

## Task 4: Setup sub-action (`setup/action.yml`)

Composite action that installs `hm` and optionally the Python DSL.

**Files:**
- Create: `setup/action.yml`

**Step 1: Write the action definition**

```yaml
name: Setup Harmont
description: Install the hm CLI and optionally the harmont Python DSL

inputs:
  version:
    description: >
      hm version to install. Use 'latest' for the most recent release,
      or pin to a specific version (e.g. '0.5.0' or 'v0.5.0').
    required: false
    default: latest
  install-python-dsl:
    description: >
      Install the harmont Python DSL package. Set to 'true' if your
      pipelines are written in Python (.harmont/*.py).
    required: false
    default: 'false'
  python-dsl-version:
    description: >
      Version of the harmont PyPI package. Only used when
      install-python-dsl is 'true'.
    required: false
    default: ''
  token:
    description: >
      GitHub token for downloading release assets and API rate limits.
      Defaults to the automatic GITHUB_TOKEN.
    required: false
    default: ${{ github.token }}

outputs:
  hm-version:
    description: Installed hm version string
    value: ${{ steps.install.outputs.hm-version }}

runs:
  using: composite
  steps:
    - name: Resolve version
      id: version
      shell: bash
      run: |
        tag=$("${{ github.action_path }}/../scripts/resolve-version.sh" "${{ inputs.version }}")
        echo "tag=$tag" >> "$GITHUB_OUTPUT"
      env:
        GITHUB_TOKEN: ${{ inputs.token }}

    - name: Install hm
      id: install
      shell: bash
      run: "${{ github.action_path }}/../scripts/install-hm.sh" "${{ steps.version.outputs.tag }}"

    - name: Install Python DSL
      if: inputs.install-python-dsl == 'true'
      shell: bash
      run: |
        pip_spec="harmont"
        if [[ -n "${{ inputs.python-dsl-version }}" ]]; then
          pip_spec="harmont==${{ inputs.python-dsl-version }}"
        fi
        echo "::group::Installing harmont Python DSL"
        pip install "$pip_spec"
        echo "::endgroup::"
```

**Step 2: Validate YAML is well-formed**

Run: `python3 -c "import yaml; yaml.safe_load(open('setup/action.yml'))"`
Expected: No error

**Step 3: Commit**

```bash
git add setup/action.yml
git commit -m "feat: add setup sub-action for hm CLI installation"
```

---

## Task 5: Cache restore sub-action (`cache-restore/action.yml`)

Wraps the `actions/cache/restore` + `hm cache restore` pattern from harmont's dogfood job.

**Files:**
- Create: `cache-restore/action.yml`

**Step 1: Write the action definition**

Key design decisions lifted from harmont's CI:
- Primary key intentionally never matches → forces prefix-based restore of most recent cache
- Prefix `harmont-v1-` allows cache invalidation by bumping the version
- Cache path is `.harmont-cache/` relative to working directory

```yaml
name: Restore Harmont Cache
description: >
  Restore Docker image cache for harmont pipelines.
  Uses content-addressed GHA cache with prefix matching
  to always get the most recent cache entry.

inputs:
  cache-key-prefix:
    description: >
      Prefix for the cache key. Bump this to force a full cache rebuild.
    required: false
    default: harmont-v1
  working-directory:
    description: Directory where .harmont-cache/ lives (usually repo root)
    required: false
    default: .

outputs:
  cache-hit:
    description: Whether a cache entry was restored
    value: ${{ steps.restore.outputs.cache-hit }}

runs:
  using: composite
  steps:
    - name: Restore GHA cache
      id: restore
      uses: actions/cache/restore@v4
      with:
        path: ${{ inputs.working-directory }}/.harmont-cache/
        key: ${{ inputs.cache-key-prefix }}-will-never-match
        restore-keys: |
          ${{ inputs.cache-key-prefix }}-

    - name: Load Docker images from cache
      if: steps.restore.outputs.cache-hit != ''
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      run: |
        echo "::group::Loading cached Docker images"
        hm cache restore .harmont-cache/
        echo "::endgroup::"
```

**Step 2: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('cache-restore/action.yml'))"`
Expected: No error

**Step 3: Commit**

```bash
git add cache-restore/action.yml
git commit -m "feat: add cache-restore sub-action wrapping hm cache restore"
```

---

## Task 6: Cache save sub-action (`cache-save/action.yml`)

Wraps `hm cache save` + `actions/cache/save` with content-addressed keys. Designed to run with `if: always()` so cache is saved even on pipeline failure.

**Files:**
- Create: `cache-save/action.yml`

**Step 1: Write the action definition**

```yaml
name: Save Harmont Cache
description: >
  Save Docker image cache after a harmont pipeline run.
  Exports images via 'hm cache save' and uploads to GHA cache
  with a content-addressed key. Use with 'if: always()' to save
  cache even when the pipeline fails.

inputs:
  cache-key-prefix:
    description: >
      Must match the prefix used in cache-restore. Bump to force rebuild.
    required: false
    default: harmont-v1
  working-directory:
    description: Directory where .harmont-cache/ lives (usually repo root)
    required: false
    default: .

runs:
  using: composite
  steps:
    - name: Export Docker images to cache dir
      id: manifest
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      run: |
        echo "::group::Saving Docker images"
        hash=$(hm cache save .harmont-cache/)
        echo "cache-key=${{ inputs.cache-key-prefix }}-${hash}" >> "$GITHUB_OUTPUT"
        echo "::endgroup::"

    - name: Upload cache
      uses: actions/cache/save@v4
      with:
        path: ${{ inputs.working-directory }}/.harmont-cache/
        key: ${{ steps.manifest.outputs.cache-key }}
```

**Step 2: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('cache-save/action.yml'))"`
Expected: No error

**Step 3: Commit**

```bash
git add cache-save/action.yml
git commit -m "feat: add cache-save sub-action with content-addressed keys"
```

---

## Task 7: All-in-one root action (`action.yml`)

Composes setup + cache-restore + `hm run` + cache-save into a single step. This is the primary entry point for new users.

**Files:**
- Create: `action.yml`

**Step 1: Write the action definition**

```yaml
name: Harmont
description: >
  Run a harmont pipeline in GitHub Actions with automatic Docker
  image caching. One step to go from zero to running pipelines.

branding:
  icon: terminal
  color: purple

inputs:
  pipeline:
    description: >
      Pipeline slug to run (e.g. 'ci'). If omitted and the repo has
      only one pipeline, harmont auto-selects it.
    required: false
    default: ''
  version:
    description: hm CLI version ('latest' or semver like '0.5.0')
    required: false
    default: latest
  working-directory:
    description: >
      Path to the repo root where .harmont/ pipelines live.
    required: false
    default: .
  parallelism:
    description: >
      Max concurrent pipeline chains. Defaults to host CPU count.
    required: false
    default: ''
  cache:
    description: Enable Docker image caching between runs
    required: false
    default: 'true'
  cache-key-prefix:
    description: Cache key prefix. Bump to force full cache rebuild.
    required: false
    default: harmont-v1
  install-python-dsl:
    description: Install the harmont Python DSL from PyPI
    required: false
    default: 'true'
  python-dsl-version:
    description: Pinned version of harmont PyPI package
    required: false
    default: ''
  extra-args:
    description: Additional arguments passed to 'hm run'
    required: false
    default: ''
  token:
    description: GitHub token for API access
    required: false
    default: ${{ github.token }}

outputs:
  hm-version:
    description: Installed hm CLI version
    value: ${{ steps.setup.outputs.hm-version }}

runs:
  using: composite
  steps:
    # --- Setup ---
    - name: Setup Harmont
      id: setup
      uses: ./setup
      with:
        version: ${{ inputs.version }}
        install-python-dsl: ${{ inputs.install-python-dsl }}
        python-dsl-version: ${{ inputs.python-dsl-version }}
        token: ${{ inputs.token }}

    # --- Cache Restore ---
    - name: Restore Docker cache
      if: inputs.cache == 'true'
      uses: ./cache-restore
      with:
        cache-key-prefix: ${{ inputs.cache-key-prefix }}
        working-directory: ${{ inputs.working-directory }}

    # --- Run Pipeline ---
    - name: Run harmont pipeline
      shell: bash
      working-directory: ${{ inputs.working-directory }}
      env:
        HM_NONINTERACTIVE: '1'
      run: |
        args=()
        if [[ -n "${{ inputs.pipeline }}" ]]; then
          args+=("${{ inputs.pipeline }}")
        fi
        if [[ -n "${{ inputs.parallelism }}" ]]; then
          args+=("--parallelism" "${{ inputs.parallelism }}")
        fi
        if [[ -n "${{ inputs.extra-args }}" ]]; then
          # Word-split extra-args intentionally
          read -ra extra <<< "${{ inputs.extra-args }}"
          args+=("${extra[@]}")
        fi
        hm run "${args[@]}"

    # --- Cache Save ---
    - name: Save Docker cache
      if: always() && inputs.cache == 'true'
      uses: ./cache-save
      with:
        cache-key-prefix: ${{ inputs.cache-key-prefix }}
        working-directory: ${{ inputs.working-directory }}
```

**Step 2: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('action.yml'))"`
Expected: No error

**Step 3: Commit**

```bash
git add action.yml
git commit -m "feat: add all-in-one root action composing setup + cache + run"
```

---

## Task 8: Integration test workflow

A workflow that exercises the action end-to-end. Uses a minimal inline harmont pipeline to verify the full flow.

**Files:**
- Create: `.github/workflows/test-action.yml`
- Create: `tests/fixtures/.harmont/hello.py`

**Step 1: Create a minimal test pipeline**

```python
import harmont as hm


@hm.pipeline("hello")
def hello() -> hm.Step:
    return hm.sh("echo 'hello from harmont action test'", label="greet")
```

**Step 2: Write the test workflow**

```yaml
name: Test Action

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  all-in-one:
    name: All-in-one action
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Run harmont via all-in-one action
        uses: ./
        with:
          pipeline: hello
          working-directory: tests/fixtures
          cache: 'true'

  granular:
    name: Granular sub-actions
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Setup hm
        uses: ./setup
        with:
          version: latest
          install-python-dsl: 'true'

      - name: Restore cache
        uses: ./cache-restore

      - name: Run pipeline manually
        working-directory: tests/fixtures
        env:
          HM_NONINTERACTIVE: '1'
        run: hm run hello

      - name: Save cache
        if: always()
        uses: ./cache-save

  setup-only:
    name: Setup only (verify install)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup hm
        id: setup
        uses: ./setup
        with:
          version: latest

      - name: Verify hm is on PATH
        run: |
          hm --version
          echo "Installed version: ${{ steps.setup.outputs.hm-version }}"
```

**Step 3: Commit**

```bash
git add tests/fixtures/.harmont/hello.py .github/workflows/test-action.yml
git commit -m "feat: add integration test workflow with fixture pipeline"
```

---

## Task 9: Update CI workflow with complete checks

Now that all files exist, update CI to lint everything and add YAML validation.

**Files:**
- Modify: `.github/workflows/ci.yml`

**Step 1: Update the CI workflow**

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  shellcheck:
    name: ShellCheck
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run ShellCheck
        uses: ludeeus/action-shellcheck@2.0.0
        with:
          scandir: scripts/

  bats:
    name: Bats tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install bats
        run: sudo apt-get update && sudo apt-get install -y bats
      - name: Run tests
        run: bats tests/*.bats

  yaml-lint:
    name: Validate action YAML
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate all action.yml files
        run: |
          for f in action.yml setup/action.yml cache-restore/action.yml cache-save/action.yml; do
            echo "Validating $f..."
            python3 -c "import yaml; yaml.safe_load(open('$f'))"
          done
          echo "All action YAML files valid."
```

**Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "chore: add YAML validation to CI"
```

---

## Task 10: Final review and polish

**Step 1: Run ShellCheck locally**

Run: `shellcheck scripts/*.sh`
Expected: No warnings (or fix any that appear)

**Step 2: Run bats locally**

Run: `bats tests/*.bats`
Expected: All tests pass

**Step 3: Verify all YAML files parse**

Run: `for f in action.yml setup/action.yml cache-restore/action.yml cache-save/action.yml; do python3 -c "import yaml; yaml.safe_load(open('$f'))" && echo "OK: $f"; done`
Expected: All OK

**Step 4: Review the composite action `uses:` references**

Verify that:
- `action.yml` uses `./setup`, `./cache-restore`, `./cache-save` (relative paths)
- `setup/action.yml` references `${{ github.action_path }}/../scripts/` (correct traversal)

**Step 5: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "chore: polish scripts and fix lint warnings"
```

---

## Design Decisions Log

### Why composite actions (not JavaScript)?
- Zero build step, zero node_modules — the action works from a tag checkout
- Shell scripts are transparent and auditable
- `actions/cache` handles the hard parts (GHA cache API) already
- Composite actions support `if: always()` on steps, which solves the post-step cache save problem

### Why separate cache-restore and cache-save?
- Harmont's own CI uses `actions/cache/restore` and `actions/cache/save` separately (not the combined `actions/cache`) because the cache key is only known after `hm cache save` computes the content hash
- Splitting lets users do work between restore and save (e.g., multiple `hm run` calls)
- The `if: always()` pattern for save is explicit and visible in user workflows

### Why the "never-match primary key" pattern?
Lifted directly from harmont's dogfood job. The primary key `harmont-v1-will-never-match` intentionally never matches exactly, forcing GHA to use `restore-keys` prefix matching. This always restores the most recent cache entry rather than an exact stale match. Combined with content-addressed save keys (`harmont-v1-${hash}`), this ensures:
- Cache is always warm (prefix match)
- New entries are only created when images change (content hash)
- No cache thrashing

### Why default `install-python-dsl: 'true'` in root action but `'false'` in setup?
- Root action is the "just works" path → install everything the user likely needs
- Setup sub-action is the "I know what I'm doing" path → minimal by default

### Why `HM_NONINTERACTIVE=1`?
Harmont prompts for user input in some scenarios. In CI there's no TTY, so this env var tells harmont to use defaults or fail instead of hanging.

### Fallback install chain: release binary → cargo-binstall → cargo install
- Prebuilt binary: fastest, no toolchain needed (seconds)
- cargo-binstall: fast, auto-detects platform binaries from crates.io metadata
- cargo install: always works but slow (compiles from source, minutes)
- Most users will hit the fast path once harmont publishes release binaries
