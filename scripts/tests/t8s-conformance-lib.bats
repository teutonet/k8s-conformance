#!/usr/bin/env bats

setup() {
  LIB="${BATS_TEST_DIRNAME}/../lib/t8s-conformance.sh"
  source "$LIB"
  FIXTURE_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$FIXTURE_DIR"
}

@test "junit_is_successful: true when errors and failures are both 0" {
  cat > "${FIXTURE_DIR}/junit_01.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
  <testsuites tests="7390" disabled="6914" errors="0" failures="0" time="1604.01">
  </testsuites>
EOF
  run junit_is_successful "${FIXTURE_DIR}/junit_01.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "junit_is_successful: false when failures is nonzero" {
  cat > "${FIXTURE_DIR}/junit_01.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
  <testsuites tests="7390" disabled="6914" errors="0" failures="2" time="1604.01">
  </testsuites>
EOF
  run junit_is_successful "${FIXTURE_DIR}/junit_01.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "junit_is_successful: false when errors is nonzero" {
  cat > "${FIXTURE_DIR}/junit_01.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
  <testsuites tests="7390" disabled="6914" errors="1" failures="0" time="1604.01">
  </testsuites>
EOF
  run junit_is_successful "${FIXTURE_DIR}/junit_01.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "junit_is_successful: fails on missing file" {
  run junit_is_successful "${FIXTURE_DIR}/does-not-exist.xml"
  [ "$status" -eq 1 ]
}

@test "junit_is_successful: fails when no testsuites element present" {
  echo "not xml" > "${FIXTURE_DIR}/junit_01.xml"
  run junit_is_successful "${FIXTURE_DIR}/junit_01.xml"
  [ "$status" -eq 1 ]
}

@test "highest_version_below: picks the highest version under target" {
  run highest_version_below "1.36" "1.24" "1.35" "1.33"
  [ "$status" -eq 0 ]
  [ "$output" = "1.35" ]
}

@test "highest_version_below: ignores versions equal to or above target" {
  run highest_version_below "1.36" "1.36" "1.37" "1.30"
  [ "$status" -eq 0 ]
  [ "$output" = "1.30" ]
}

@test "highest_version_below: fails when nothing qualifies" {
  run highest_version_below "1.20" "1.24" "1.35"
  [ "$status" -eq 1 ]
}

@test "highest_version_below: handles double-digit minors correctly" {
  run highest_version_below "1.10" "1.2" "1.9" "1.10"
  [ "$status" -eq 0 ]
  [ "$output" = "1.9" ]
}

@test "set_readme_kubernetes_version: replaces a patch version with the bare minor" {
  echo "The output here was obtained with hydrophone 0.7.0 running on a Kubernetes 1.35.2 cluster." > "${FIXTURE_DIR}/README.md"
  set_readme_kubernetes_version "1.36" "${FIXTURE_DIR}/README.md"
  run cat "${FIXTURE_DIR}/README.md"
  [ "$output" = "The output here was obtained with hydrophone 0.7.0 running on a Kubernetes 1.36 cluster." ]
}

@test "set_readme_kubernetes_version: replaces a bare minor version" {
  echo "Tested on a Kubernetes 1.35 cluster." > "${FIXTURE_DIR}/README.md"
  set_readme_kubernetes_version "1.36" "${FIXTURE_DIR}/README.md"
  run cat "${FIXTURE_DIR}/README.md"
  [ "$output" = "Tested on a Kubernetes 1.36 cluster." ]
}

@test "set_readme_kubernetes_version: leaves unrelated 'Kubernetes' mentions alone" {
  printf '# t8s Kubernetes Engine\n\nTested on a Kubernetes 1.35.2 cluster.\n' > "${FIXTURE_DIR}/README.md"
  set_readme_kubernetes_version "1.36" "${FIXTURE_DIR}/README.md"
  run head -n1 "${FIXTURE_DIR}/README.md"
  [ "$output" = "# t8s Kubernetes Engine" ]
}
