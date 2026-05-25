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
  source "$INSTALL"
  INSTALL_DIR="$TMPDIR/bin"
  mkdir -p "$INSTALL_DIR"
  register_path "$INSTALL_DIR"
  grep -q "$INSTALL_DIR" "$GITHUB_PATH"
}
