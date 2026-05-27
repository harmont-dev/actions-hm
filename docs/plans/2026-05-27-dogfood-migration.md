# Dogfood Pipeline Migration: harmont-cli-2 → actions-hm

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable `harmont-cli-2`'s dogfood CI job to use `actions-hm` sub-actions for Docker image caching, replacing 8 manual cache steps with 2 action calls while preserving the build-from-source requirement.

**Architecture:** Add a `hm-path` input to `cache-save/action.yml` so it can use a locally-built binary instead of requiring `hm` on `$PATH`. The `cache-restore` sub-action already works without `hm` (pure Docker operations). The root all-in-one action stays unchanged — it's for end users, not dogfood. The dogfood workflow will use the granular sub-actions directly, skipping `setup/` entirely (it builds from source).

**Tech Stack:** YAML (composite actions), Bash (shell scripts), GitHub Actions, GHCR (registry cache)

---

## Evaluation Summary

### What the dogfood pipeline does today

In `harmont-cli-2/.github/workflows/ci.yml`, the `dogfood` job:

1. Builds `hm` from source (`cargo build -p harmont-cli`)
2. Enables FUSE `allow_other` (`sudo sed -i ...`)
3. Restores `.harmont-cache/` from GHA file cache (`actions/cache/restore@v4`)
4. Loads Docker images (`./target/debug/hm cache restore .harmont-cache/`)
5. Runs the pipeline (`./target/debug/hm run ci`)
6. Exports manifest (`./target/debug/hm cache save .harmont-cache/`)
7. Computes content-addressed key from hash output
8. Saves `.harmont-cache/` to GHA file cache (`actions/cache/save@v4`)

Steps 3-4 and 6-8 are caching boilerplate. Steps 1-2 and 5 are dogfood-specific.

### What actions-hm provides today

| Sub-action | What it does | Needs `hm` binary? | Dogfood-compatible? |
|---|---|---|---|
| `setup/` | Downloads released binary | N/A | **No** — dogfood builds from source |
| `cache-restore/` | Docker login → pull manifest image → pull cached images → retag | **No** | **Yes** |
| `cache-save/` | `hm cache save` → push images → push manifest image → cleanup stale | **Yes** (calls `hm cache save`) | **Almost** — needs `hm` on PATH |

### Gap analysis

| Gap | Severity | Fix |
|---|---|---|
| `cache-save` hardcodes `hm` command name | **Blocking** | Add `hm-path` input, default `hm` |
| No FUSE setup | **Non-issue** | Dogfood handles this before the action |
| No `cargo build` | **Non-issue** | Dogfood handles this before the action |
| Registry cache vs GHA file cache | **Upgrade** | GHCR has no 10GB limit, native layer dedup |
| Needs `packages:write` + `packages:delete` permissions | **Minor** | Already standard for GHCR; add to dogfood workflow permissions |

### Migration benefit

**Before (8 steps):**
```yaml
- uses: actions/cache/restore@v4       # restore GHA cache
- run: hm cache restore .harmont-cache/  # load images
- run: hm run ci                          # run pipeline
- run: hm cache save .harmont-cache/      # export manifest
- uses: actions/cache/save@v4            # save GHA cache
```
Plus `id:`, `if:`, `key:`, `restore-keys:` boilerplate on each step.

**After (3 steps):**
```yaml
- uses: harmont-dev/actions-hm/cache-restore@v1  # pull from GHCR
- run: ./target/debug/hm run ci                    # run pipeline
- uses: harmont-dev/actions-hm/cache-save@v1      # push to GHCR + cleanup
```

Also gains automatic stale image cleanup (keeps N old versions per step).

---

## Task 1: Add `hm-path` input to `cache-save/action.yml`

The `cache-save` sub-action calls `hm cache save .harmont-cache/` on line 63. The dogfood pipeline builds `hm` at `./target/debug/hm` — it's not on `$PATH`. Adding an `hm-path` input lets callers point to a custom binary.

**Files:**
- Modify: `cache-save/action.yml:1-10` (add input)
- Modify: `cache-save/action.yml:60-65` (use input in run step)

**Step 1: Write the failing test scenario**

No bats test exists for sub-actions (they're integration-tested via `test-action.yml`). Verify manually that current `cache-save` hardcodes `hm`:

Run: `grep -n 'hm cache save' cache-save/action.yml`
Expected: Line ~63, `hm cache save .harmont-cache/`

**Step 2: Add `hm-path` input to `cache-save/action.yml`**

Add to the `inputs:` block after `token:`:

```yaml
  hm-path:
    description: >
      Path to the hm binary. Defaults to 'hm' (assumes it's on PATH).
      Use './target/debug/hm' or similar when testing a locally-built binary.
    required: false
    default: hm
```

**Step 3: Wire `hm-path` into the export step**

In the "Export manifest and push images" step, add `INPUT_HM_PATH: ${{ inputs.hm-path }}` to the `env:` block and replace the `hm cache save` call:

Change line ~63 from:
```bash
hm cache save .harmont-cache/ > /dev/null
```
To:
```bash
"$INPUT_HM_PATH" cache save .harmont-cache/ > /dev/null
```

**Step 4: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('cache-save/action.yml'))"`
Expected: No error

**Step 5: Commit**

```bash
git add cache-save/action.yml
git commit -m "feat(cache-save): add hm-path input for custom binary location"
```

---

## Task 2: Wire `hm-path` through root `action.yml`

The root all-in-one action should pass through `hm-path` to `cache-save` so power users of the root action can also use a custom binary. This keeps the granular and all-in-one paths consistent.

**Files:**
- Modify: `action.yml:10-60` (add input)
- Modify: `action.yml:90-123` (pass to run step and cache-save)

**Step 1: Add `hm-path` input to root `action.yml`**

Add to inputs after `extra-args`:

```yaml
  hm-path:
    description: >
      Path to the hm binary. Use when testing a locally-built binary
      instead of an installed release. Overrides setup step.
    required: false
    default: ''
```

**Step 2: Make the run step use `hm-path` when set**

In the "Run harmont pipeline" step, change the env block to include:
```yaml
INPUT_HM_PATH: ${{ inputs.hm-path || 'hm' }}
```

And change the run command from `hm run "${args[@]}"` to `"$INPUT_HM_PATH" run "${args[@]}"`.

**Step 3: Pass `hm-path` to cache-save**

In the "Save Docker cache" step, add:
```yaml
hm-path: ${{ inputs.hm-path || 'hm' }}
```

**Step 4: Conditionally skip setup when hm-path is set**

Add `if: inputs.hm-path == ''` to the "Setup Harmont" step. If the user provides their own binary, there's no need to download one.

**Step 5: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('action.yml'))"`
Expected: No error

**Step 6: Commit**

```bash
git add action.yml
git commit -m "feat: wire hm-path through root action, skip setup when provided"
```

---

## Task 3: Add `hm-path` to integration tests

Verify the new input works in CI by adding a test job that builds `hm` from source (or mocks it) and uses `hm-path`.

**Files:**
- Modify: `.github/workflows/test-action.yml`

**Step 1: Add a `custom-binary` test job**

Add after the existing jobs:

```yaml
  custom-binary:
    name: Custom hm-path (dogfood pattern)
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - name: Create mock hm binary
        run: |
          mkdir -p /tmp/mock-hm
          cat > /tmp/mock-hm/hm << 'SCRIPT'
          #!/bin/bash
          case "$1" in
            --version) echo "mock-0.0.1" ;;
            cache)
              case "$2" in
                save)
                  mkdir -p "$3"
                  echo '{"images":{}}' > "$3/manifest.json"
                  echo "abc123"
                  ;;
                restore) echo "restored" ;;
              esac
              ;;
            run) echo "ran pipeline: $2" ;;
          esac
          SCRIPT
          chmod +x /tmp/mock-hm/hm

      - name: Cache restore (no manifest yet, cold start)
        uses: ./cache-restore
        with:
          working-directory: tests/fixtures

      - name: Run with custom binary
        working-directory: tests/fixtures
        env:
          HM_NONINTERACTIVE: '1'
        run: /tmp/mock-hm/hm run hello

      - name: Cache save with custom binary
        if: always()
        uses: ./cache-save
        with:
          working-directory: tests/fixtures
          hm-path: /tmp/mock-hm/hm
```

**Step 2: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/test-action.yml'))"`
Expected: No error

**Step 3: Commit**

```bash
git add .github/workflows/test-action.yml
git commit -m "test: add integration test for custom hm-path (dogfood pattern)"
```

---

## Task 4: Write the migrated dogfood workflow

Create the replacement dogfood job that uses `actions-hm` sub-actions. This lives in `harmont-cli-2`, not this repo. Document it here as a reference for the migration PR.

**Files:**
- Reference only: `harmont-cli-2/.github/workflows/ci.yml` (dogfood job)

**Step 1: Document the target workflow**

The migrated `dogfood` job in `harmont-cli-2/.github/workflows/ci.yml` should look like:

```yaml
  dogfood:
    name: dogfood (hm run ci)
    runs-on: ubuntu-latest
    timeout-minutes: 45
    permissions:
      contents: read
      packages: write
      packages: delete  # for stale image cleanup
    steps:
      - uses: actions/checkout@v4

      - uses: dtolnay/rust-toolchain@stable

      - uses: Swatinem/rust-cache@v2

      - uses: actions/setup-node@v4
        with:
          node-version: "23"
          cache: npm
          cache-dependency-path: dsls/harmont-ts/package-lock.json

      - name: Install esbuild (for harmont-ts bundle)
        working-directory: dsls/harmont-ts
        run: npm ci

      - name: Build hm
        run: cargo build -p harmont-cli

      - name: Enable FUSE allow_other
        run: sudo sed -i 's/#user_allow_other/user_allow_other/' /etc/fuse.conf

      - name: Restore Docker cache
        uses: harmont-dev/actions-hm/cache-restore@v1

      - name: hm run ci
        env:
          HM_NONINTERACTIVE: '1'
        run: ./target/debug/hm run ci

      - name: Save Docker cache
        if: always()
        uses: harmont-dev/actions-hm/cache-save@v1
        with:
          hm-path: ./target/debug/hm
```

**Step 2: Diff comparison**

Lines removed from current dogfood job:
```yaml
# These 5 steps become 2 action calls:
- uses: actions/cache/restore@v4          # REMOVED
  with:
    path: .harmont-cache/
    key: harmont-v1-will-never-match
    restore-keys: harmont-v1-

- run: ./target/debug/hm cache restore .harmont-cache/  # REMOVED

- id: cache-manifest                       # REMOVED
  run: hash=$(./target/debug/hm cache save .harmont-cache/)
       echo "key=harmont-v1-${hash}" >> "$GITHUB_OUTPUT"

- uses: actions/cache/save@v4              # REMOVED
  with:
    path: .harmont-cache/
    key: ${{ steps.cache-manifest.outputs.key }}
```

Lines added:
```yaml
- uses: harmont-dev/actions-hm/cache-restore@v1   # NEW (1 step replaces 2)

- uses: harmont-dev/actions-hm/cache-save@v1      # NEW (1 step replaces 3)
  with:
    hm-path: ./target/debug/hm
```

**Net change:** -5 steps, +2 steps, +stale image cleanup for free.

**Step 3: Commit plan documentation**

```bash
git add docs/plans/2026-05-27-dogfood-migration.md
git commit -m "docs: add dogfood migration evaluation and plan"
```

---

## Task 5: Verify `cache-restore` works without `hm` binary

Confirm that `cache-restore/action.yml` has zero dependency on the `hm` binary. This is a read-only verification — no code changes expected.

**Files:**
- Read: `cache-restore/action.yml`

**Step 1: Grep for `hm` commands**

Run: `grep -n 'hm ' cache-restore/action.yml`
Expected: No matches (only Docker and Python commands)

**Step 2: Verify the restore flow**

The restore sub-action should only use:
- `docker login` — authenticate to registry
- `docker pull` — pull manifest image and cached images
- `docker create` / `docker cp` / `docker rm` — extract manifest.json
- `docker tag` — retag registry images as `harmont-local/*`
- `python3 -c` — parse manifest.json

If `hm` appears anywhere, it needs an `hm-path` input too (same as Task 1).

**Step 3: Document result**

Run: `echo "cache-restore has no hm dependency: $(grep -c 'hm cache' cache-restore/action.yml) matches"`
Expected: `0 matches` — confirmed no dependency.

---

## Task 6: Update README with dogfood/custom-binary usage

Add a section to `README.md` showing how to use the action with a locally-built binary (the dogfood pattern).

**Files:**
- Modify: `README.md`

**Step 1: Add a "Custom binary" section**

Add under the existing "Granular sub-actions" section:

```markdown
### Custom binary (dogfood pattern)

When testing a locally-built `hm` binary (e.g., the harmont-cli repo's own CI):

```yaml
- name: Build hm from source
  run: cargo build -p harmont-cli

- uses: harmont-dev/actions-hm/cache-restore@v1

- run: ./target/debug/hm run ci
  env:
    HM_NONINTERACTIVE: '1'

- uses: harmont-dev/actions-hm/cache-save@v1
  if: always()
  with:
    hm-path: ./target/debug/hm
```

The `hm-path` input tells cache-save where to find the binary. Cache-restore
doesn't need it — it uses Docker directly.
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add custom binary / dogfood usage example to README"
```

---

## Caching: GHA file cache vs GHCR registry

The migration switches caching from GHA file cache to GHCR registry. Comparison:

| | GHA file cache (current) | GHCR registry (actions-hm) |
|---|---|---|
| Size limit | 10 GB total per repo | Unlimited (GHCR storage) |
| Granularity | Single `.harmont-cache/` tarball | Per-image, per-tag |
| Layer dedup | None (full tarball each time) | Native Docker layer dedup |
| Cross-branch | Shared via prefix match | Shared (same registry) |
| Stale cleanup | Manual / GHA eviction | Automatic (configurable keep-N) |
| Auth | `GITHUB_TOKEN` (contents read) | `GITHUB_TOKEN` (packages write/delete) |
| Cold start cost | Full tarball download | Per-image parallel pulls |

**Verdict:** Registry cache is strictly better for the dogfood use case. Larger Docker image sets won't hit the 10GB cap, and layer dedup means incremental changes push/pull only deltas.

---

## Risk assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| GHCR rate limits on heavy push/pull | Low | GitHub-hosted runners have generous limits to GHCR |
| `packages:write` permission not granted | Low | Add to `permissions:` block in workflow |
| Registry cold start slower than file cache | Medium | First run pulls nothing (cold start same as today). Subsequent runs may be faster due to layer dedup |
| `hm cache save` output format changes | Low | Pin `actions-hm` to a tag; manifest.json format is stable |

---

## Execution order

Tasks 1-3 are in this repo (actions-hm). Task 4 is a migration PR in harmont-cli-2. Task 5 is verification. Task 6 is documentation.

Dependency graph:
```
Task 1 (hm-path in cache-save) ─┬─→ Task 2 (wire through root action)
                                 ├─→ Task 3 (integration test)
                                 ├─→ Task 4 (migration PR in harmont-cli-2)
                                 └─→ Task 6 (README update)
Task 5 (verify cache-restore) ──────→ (independent, can run first)
```

Tasks 2, 3, 5, 6 can all run in parallel after Task 1.
Task 4 depends on Task 1 being merged + tagged.
