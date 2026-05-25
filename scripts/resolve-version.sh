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
