#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../build-t8s-submission.sh"
  # shellcheck source=../lib/t8s-conformance.sh
  source "${BATS_TEST_DIRNAME}/../lib/t8s-conformance.sh"
  WORKDIR="$(mktemp -d)"
  STUB_BIN="$(mktemp -d)"
  export S3_ENDPOINT_URL="https://fake-endpoint.example"
  export S3_REGION="fake-region"
  # Credentialed by default so existing tests aren't affected by the
  # no_sign_request fallback; the dedicated test below unsets this.
  export S3_ACCESS_KEY_ID="dummy"
  export S3_SECRET_ACCESS_KEY="dummy"

  mkdir -p "${WORKDIR}/v1.35/t8s"
  cat > "${WORKDIR}/v1.35/t8s/PRODUCT.yaml" <<'EOF'
vendor: teuto.net Netzdienste GmbH
name: teuto.net managed kubernetes
version: x.x.x
EOF
  echo "The output here was obtained with hydrophone 0.7.0 running on a Kubernetes 1.35.2 cluster." > "${WORKDIR}/v1.35/t8s/README.md"

  # Stub `rclone` so no network access happens: `rclone copyto <src> <dest>`
  # just writes a recognisable fixture body to <dest>, matching on a
  # suffix of <src> (which is a "<connection-string>:bucket/key" blob).
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  case "$src" in
    */e2e.log) echo "fixture e2e log" > "$dest" ;;
    */junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *) echo "unexpected rclone copyto source: $src" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"
}

teardown() {
  rm -rf "$WORKDIR" "$STUB_BIN"
}

@test "build-t8s-submission: stages a new version dir from the template" {
  cd "$WORKDIR"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.36.2" "fake-bucket"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.36/t8s" ]

  run cat "v1.36/t8s/PRODUCT.yaml"
  [[ "$output" == *"version: x.x.x"* ]]

  run cat "v1.36/t8s/README.md"
  [[ "$output" == *"Kubernetes 1.36.2 cluster"* ]]
  [[ "$output" != *"1.35"* ]]

  run cat "v1.36/t8s/e2e.log"
  [ "$output" = "fixture e2e log" ]

  run cat "v1.36/t8s/junit_01.xml"
  [[ "$output" == *'errors="0" failures="0"'* ]]

  run get_t8s_version_marker "v1.36/t8s/README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "1.36.2" ]
}

@test "build-t8s-submission: updates an already-certified minor in place with a newer patch" {
  # v1.35/t8s already exists (as if certified upstream); submitting
  # 1.35.5 for the *same* minor must refresh it in place -- not try to
  # copy it onto itself (which `cp` would refuse) -- and still end up
  # with the marker/README/result files correctly updated.
  cd "$WORKDIR"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.35.5" "fake-bucket"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.35/t8s" ]

  run cat "v1.35/t8s/PRODUCT.yaml"
  [[ "$output" == *"version: x.x.x"* ]]

  run cat "v1.35/t8s/README.md"
  [[ "$output" == *"Kubernetes 1.35.5 cluster"* ]]

  run get_t8s_version_marker "v1.35/t8s/README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "1.35.5" ]

  run cat "v1.35/t8s/junit_01.xml"
  [[ "$output" == *'errors="0" failures="0"'* ]]
}

@test "build-t8s-submission: falls back to the highest existing template when target is older than all of them" {
  # Only v1.35/t8s exists upstream; backfilling 1.33 (older than 1.35)
  # must still work, using v1.35 as the structural template even though
  # it's numerically above the target.
  cd "$WORKDIR"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.33.11" "fake-bucket"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.33/t8s" ]

  run cat "v1.33/t8s/PRODUCT.yaml"
  [[ "$output" == *"version: x.x.x"* ]]

  run cat "v1.33/t8s/README.md"
  [[ "$output" == *"Kubernetes 1.33.11 cluster"* ]]
}

@test "build-t8s-submission: fails cleanly when no template version exists" {
  rm -rf "${WORKDIR:?}/v1.35"
  cd "$WORKDIR"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.36.2" "fake-bucket"
  [ "$status" -eq 1 ]
}

@test "build-t8s-submission: uses no_sign_request when S3_ACCESS_KEY_ID is unset" {
  unset S3_ACCESS_KEY_ID
  unset S3_SECRET_ACCESS_KEY
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  unsigned="false"
  [[ "$src" == *"no_sign_request=true"* ]] && unsigned="true"
  case "$dest" in
    */e2e.log) echo "fixture e2e log" > "$dest" ;;
    */junit_01.xml) echo "unsigned=${unsigned}" > "$dest" ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  cd "$WORKDIR"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.36.2" "fake-bucket"
  [ "$status" -eq 0 ]

  run cat "v1.36/t8s/junit_01.xml"
  [ "$output" = "unsigned=true" ]
}
