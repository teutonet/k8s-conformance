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

@test "set_t8s_version_marker: appends a marker to a file with none yet" {
  printf '# t8s Kubernetes Engine\n\nTested on a Kubernetes 1.35.2 cluster.\n' > "${FIXTURE_DIR}/README.md"
  set_t8s_version_marker "1.35.2" "${FIXTURE_DIR}/README.md"
  run get_t8s_version_marker "${FIXTURE_DIR}/README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "1.35.2" ]
  run head -n1 "${FIXTURE_DIR}/README.md"
  [ "$output" = "# t8s Kubernetes Engine" ]
}

@test "set_t8s_version_marker: replaces an existing marker in place instead of duplicating it" {
  printf '# t8s Kubernetes Engine\n' > "${FIXTURE_DIR}/README.md"
  set_t8s_version_marker "1.35.2" "${FIXTURE_DIR}/README.md"
  set_t8s_version_marker "1.35.5" "${FIXTURE_DIR}/README.md"
  run get_t8s_version_marker "${FIXTURE_DIR}/README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "1.35.5" ]
  run grep -c 't8s-conformance-metadata' "${FIXTURE_DIR}/README.md"
  [ "$output" = "1" ]
}

@test "set_t8s_version_marker: the marker doesn't render as visible markdown" {
  printf '# t8s Kubernetes Engine\n' > "${FIXTURE_DIR}/README.md"
  set_t8s_version_marker "1.35.2" "${FIXTURE_DIR}/README.md"
  run cat "${FIXTURE_DIR}/README.md"
  [[ "$output" == *'<!-- t8s-conformance-metadata: '* ]]
}

@test "get_t8s_version_marker: fails on a pre-automation README with no marker" {
  echo "Tested on a Kubernetes 1.35.2 cluster." > "${FIXTURE_DIR}/README.md"
  run get_t8s_version_marker "${FIXTURE_DIR}/README.md"
  [ "$status" -eq 1 ]
}

@test "oldest_supported_minor: latest stable minus two minors" {
  run oldest_supported_minor "v1.37.1"
  [ "$status" -eq 0 ]
  [ "$output" = "1.35" ]
}

@test "oldest_supported_minor: works without the leading v" {
  run oldest_supported_minor "1.30.4"
  [ "$status" -eq 0 ]
  [ "$output" = "1.28" ]
}

@test "minor_is_older_than: true only for a strictly older minor" {
  run minor_is_older_than "1.33" "1.35"
  [ "$status" -eq 0 ]
  run minor_is_older_than "1.35" "1.35"
  [ "$status" -ne 0 ]
  run minor_is_older_than "1.36" "1.35"
  [ "$status" -ne 0 ]
  run minor_is_older_than "1.9" "1.10"
  [ "$status" -eq 0 ]
}

@test "get_oldest_supported_minor: derives the window from the fetched stable version" {
  stub_dir="$(mktemp -d)"
  printf '#!/bin/bash\necho v1.37.1\n' > "${stub_dir}/curl"
  chmod +x "${stub_dir}/curl"
  PATH="${stub_dir}:${PATH}" run get_oldest_supported_minor
  rm -rf "$stub_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "1.35" ]
}

@test "get_oldest_supported_minor: fails when the fetch fails" {
  stub_dir="$(mktemp -d)"
  printf '#!/bin/bash\nexit 22\n' > "${stub_dir}/curl"
  chmod +x "${stub_dir}/curl"
  PATH="${stub_dir}:${PATH}" run get_oldest_supported_minor
  rm -rf "$stub_dir"
  [ "$status" -ne 0 ]
}

@test "set_product_version_comment: appends the comment, keeping version: untouched" {
  printf 'vendor: teuto.net\nversion: x.x.x\n' > "${FIXTURE_DIR}/PRODUCT.yaml"
  set_product_version_comment "1.35.5" "${FIXTURE_DIR}/PRODUCT.yaml"
  run cat "${FIXTURE_DIR}/PRODUCT.yaml"
  [[ "$output" == *'version: x.x.x'* ]]
  [[ "$output" == *'# kubernetes_version: 1.35.5' ]]
}

@test "set_product_version_comment: replaces an existing comment instead of duplicating it" {
  printf 'vendor: teuto.net\n' > "${FIXTURE_DIR}/PRODUCT.yaml"
  set_product_version_comment "1.35.2" "${FIXTURE_DIR}/PRODUCT.yaml"
  set_product_version_comment "1.35.5" "${FIXTURE_DIR}/PRODUCT.yaml"
  run grep -c 'kubernetes_version' "${FIXTURE_DIR}/PRODUCT.yaml"
  [ "$output" = "1" ]
  run grep 'kubernetes_version' "${FIXTURE_DIR}/PRODUCT.yaml"
  [ "$output" = "# kubernetes_version: 1.35.5" ]
}

@test "set_product_version_comment: handles a file with no trailing newline" {
  printf 'vendor: teuto.net' > "${FIXTURE_DIR}/PRODUCT.yaml"
  set_product_version_comment "1.35.5" "${FIXTURE_DIR}/PRODUCT.yaml"
  run head -n1 "${FIXTURE_DIR}/PRODUCT.yaml"
  [ "$output" = "vendor: teuto.net" ]
}
