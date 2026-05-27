# actions-hm

> [!WARNING]
>
> This repo is currently considered experimental.

Run [harmont](https://harmont.dev) pipelines in GitHub Actions.

```yaml
- uses: harmont-dev/actions-hm@main
  with:
    pipeline: ci
```

## Usage

### Minimal (all-in-one)

```yaml
name: CI

on: [push, pull_request]

permissions:
  contents: read
  packages: write

jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: harmont-dev/actions-hm@v1
        with:
          pipeline: ci
```

### Multiple pipelines

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: harmont-dev/actions-hm@main
        with:
          pipeline: lint

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: harmont-dev/actions-hm@main
        with:
          pipeline: test
          parallelism: 4
```

### Granular sub-actions

For workflows that need custom steps between setup, cache, and run:

```yaml
jobs:
  ci:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: harmont-dev/actions-hm/setup@v1

      - uses: harmont-dev/actions-hm/cache-restore@v1

      - run: |
          echo "Custom setup between cache restore and pipeline run"
          hm run ci

      - uses: harmont-dev/actions-hm/cache-save@v1
        if: always()
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `pipeline` | *(auto)* | Pipeline slug to run. Omit if repo has only one pipeline. |
| `version` | `latest` | `hm` CLI version (`latest` or semver like `0.5.0`) |
| `working-directory` | `.` | Path to repo root where `.harmont/` lives |
| `parallelism` | *(cpu count)* | Max concurrent pipeline chains |
| `cache` | `true` | Enable Docker image caching |
| `cache-registry` | `ghcr.io` | Container registry for image caching |
| `cache-registry-prefix` | *(auto)* | Registry path prefix. Default: `ghcr.io/<owner>/<repo>/harmont-cache` |
| `cache-cleanup` | `true` | Delete stale images from registry after save |
| `cache-cleanup-keep` | `2` | Number of old image versions to keep per step |
| `hm-path` | | Path to a locally-built `hm` binary (skips install; used for dogfooding) |
| `extra-args` | | Additional arguments passed to `hm run` |
| `token` | `github.token` | GitHub token (needs `packages:write`, `packages:delete` for cleanup) |

## Outputs

| Output | Description |
|--------|-------------|
| `hm-version` | Installed `hm` CLI version |

## Sub-actions

| Action | Purpose |
|--------|---------|
| `harmont-dev/actions-hm/setup@v1` | Install `hm` binary (cached between runs) |
| `harmont-dev/actions-hm/cache-restore@v1` | Pull cached Docker images from registry |
| `harmont-dev/actions-hm/cache-save@v1` | Push Docker images to registry + cleanup |

## How caching works

```
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions Runner                                       │
│                                                              │
│  1. Pull manifest:latest from GHCR                          │
│  2. Pull each step image (layer dedup = fast)               │
│  3. Re-tag as harmont-local/* so hm recognizes them         │
│  4. hm run ci (uses cached images, skips rebuilds)          │
│  5. Push changed images back to GHCR                        │
│  6. Prune images older than cleanup-keep                    │
│                                                              │
│  Images stored at:                                           │
│  ghcr.io/<owner>/<repo>/harmont-cache/<step>:<hash>         │
└─────────────────────────────────────────────────────────────┘
```

**Why GHCR instead of `actions/cache`?**

- No 10 GB size limit (GHCR storage is unlimited for public repos)
- Native Docker layer deduplication — shared base images stored once
- Per-image granularity — only changed images push/pull
- Faster for large images than tar/untar through GHA cache

## Permissions

The action needs `packages:write` on the `GITHUB_TOKEN` to push/pull cache images. For cleanup, it also needs `packages:delete`.

```yaml
permissions:
  contents: read
  packages: write
```

> **Note:** `packages:delete` is included in `packages:write` for tokens with full `packages` scope. If using a fine-grained PAT, ensure both are granted.

## Migrating from raw workflow steps

If you currently have a manual harmont setup in your workflow:

<details>
<summary>Before (manual setup)</summary>

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable
  - uses: Swatinem/rust-cache@v2
  - run: cargo build -p harmont-cli
  - uses: actions/cache/restore@v4
    with:
      path: .harmont-cache/
      key: harmont-v1-will-never-match
      restore-keys: harmont-v1-
  - run: ./target/debug/hm cache restore .harmont-cache/
  - run: ./target/debug/hm run ci
    env:
      HM_NONINTERACTIVE: '1'
  - run: |
      hash=$(./target/debug/hm cache save .harmont-cache/)
      echo "key=harmont-v1-${hash}" >> "$GITHUB_OUTPUT"
    id: cache-manifest
    if: always()
  - uses: actions/cache/save@v4
    if: always()
    with:
      path: .harmont-cache/
      key: ${{ steps.cache-manifest.outputs.key }}
```

</details>

<details>
<summary>After (this action)</summary>

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: harmont-dev/actions-hm@main
    with:
      pipeline: ci
```

</details>

## FAQ

### Do I need Docker on the runner?

Yes. Harmont runs pipeline steps in Docker containers. Use `runs-on: ubuntu-latest` (Docker is pre-installed).

### What about macOS / Windows runners?

macOS runners have Docker available via colima/lima. Windows runners are not currently supported (harmont requires Linux containers).

### Can I use a private registry instead of GHCR?

Yes. Set `cache-registry` to your registry hostname and provide a token with push/pull access:

```yaml
- uses: harmont-dev/actions-hm@main
  with:
    pipeline: ci
    cache-registry: registry.example.com
    token: ${{ secrets.REGISTRY_TOKEN }}
```

### How do I disable caching entirely?

```yaml
- uses: harmont-dev/actions-hm@main
  with:
    pipeline: ci
    cache: 'false'
```

### How do I force a clean cache rebuild?

Delete the `harmont-cache` packages from your repo's GitHub Packages, or change `cache-registry-prefix` to a new path.

### The first run is slow — is that expected?

Yes. The first run has no cached images, so Docker pulls base images and builds from scratch. Subsequent runs reuse cached images and are significantly faster.

### What permissions does cleanup need?

`packages:delete` (part of the `packages: write` scope). If your token lacks this, set `cache-cleanup: 'false'` — images accumulate but nothing breaks.

## License

MIT
