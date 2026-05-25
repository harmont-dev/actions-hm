#!/usr/bin/env bash
set -euo pipefail

REPO="harmont-dev/harmont-cli"

detect_platform() {
  local os="${OS:-$(uname -s)}"
  local arch="${ARCH:-$(uname -m)}"

  local os_part arch_part

  case "$os" in
    Linux)  os_part="unknown-linux-gnu" ;;
    Darwin) os_part="apple-darwin" ;;
    *)
      echo "::error::Unsupported OS: $os" >&2
      return 1
      ;;
  esac

  case "$arch" in
    x86_64)        arch_part="x86_64" ;;
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
  local VERSION="${1:?version tag required (e.g. v0.5.0)}"
  local INSTALL_DIR="${2:-${RUNNER_TOOL_CACHE:-/tmp}/hm/bin}"

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
  main "$@"
fi
