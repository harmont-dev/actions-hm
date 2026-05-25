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
