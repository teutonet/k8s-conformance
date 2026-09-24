#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../build-t8s-submission.sh"
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
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.36" "fake-bucket"
  [ "$status" -eq 0 ]
  [ "$output" = "v1.36/t8s" ]

  run cat "v1.36/t8s/PRODUCT.yaml"
  [[ "$output" == *"version: x.x.x"* ]]

  run cat "v1.36/t8s/README.md"
  [[ "$output" == *"Kubernetes 1.36 cluster"* ]]
  [[ "$output" != *"1.35"* ]]

  run cat "v1.36/t8s/e2e.log"
  [ "$output" = "fixture e2e log" ]

  run cat "v1.36/t8s/junit_01.xml"
  [[ "$output" == *'errors="0" failures="0"'* ]]
}

@test "build-t8s-submission: fails cleanly when no template version exists" {
  rm -rf "${WORKDIR:?}/v1.35"
  cd "$WORKDIR"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.36" "fake-bucket"
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
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "1.36" "fake-bucket"
  [ "$status" -eq 0 ]

  run cat "v1.36/t8s/junit_01.xml"
  [ "$output" = "unsigned=true" ]
}
