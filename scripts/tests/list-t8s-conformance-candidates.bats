#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../list-t8s-conformance-candidates.sh"
  STUB_BIN="$(mktemp -d)"
  export S3_ENDPOINT_URL="https://fake-endpoint.example"
  export S3_REGION="fake-region"
  # Credentialed by default so existing tests aren't affected by the
  # no_sign_request fallback; the dedicated test below unsets this.
  export S3_ACCESS_KEY_ID="dummy"
  export S3_SECRET_ACCESS_KEY="dummy"

  # Bucket has three minors: 1.35 (already certified upstream, per the
  # `gh` stub below), 1.36 (clean run, not certified, no open PR -> a
  # candidate), 1.37 (failing run -> not a candidate).
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  cat <<'LIST'
v1.35/
v1.36/
v1.37/
LIST
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  case "$src" in
    *v1.35/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *v1.36/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *v1.37/junit_01.xml) echo '<testsuites errors="0" failures="3"></testsuites>' > "$dest" ;;
    *) echo "unexpected rclone copyto source: $src" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  cat > "${STUB_BIN}/gh" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "api" && "$2" == "repos/cncf/k8s-conformance/contents/v1.35/t8s/PRODUCT.yaml" ]]; then
  exit 0
fi
if [[ "$1" == "api" && "$2" == repos/cncf/k8s-conformance/contents/v1.36/t8s/PRODUCT.yaml ]]; then
  exit 1
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo 0
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
}

teardown() {
  rm -rf "$STUB_BIN"
}

@test "list-t8s-conformance-candidates: keeps only the clean, uncertified minor" {
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == ["1.36"]'
}

@test "list-t8s-conformance-candidates: skips a minor with a malformed junit_01.xml instead of aborting" {
  # Bucket has two minors: 1.35 (malformed junit -> no <testsuites> element,
  # must be skipped without killing the whole run), 1.36 (clean run, not
  # certified, no open PR -> a candidate).
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  cat <<'LIST'
v1.35/
v1.36/
LIST
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  case "$src" in
    *v1.35/junit_01.xml) echo '<malformed/>' > "$dest" ;;
    *v1.36/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *) echo "unexpected rclone copyto source: $src" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  cat > "${STUB_BIN}/gh" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "api" && "$2" == repos/cncf/k8s-conformance/contents/v1.36/t8s/PRODUCT.yaml ]]; then
  exit 1
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo 0
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == ["1.36"]'
}

@test "list-t8s-conformance-candidates: exits nonzero when rclone lsf fails" {
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  echo "rclone: could not connect to the endpoint URL" >&2
  exit 1
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -ne 0 ]
}

@test "list-t8s-conformance-candidates: uses no_sign_request when S3_ACCESS_KEY_ID is unset" {
  unset S3_ACCESS_KEY_ID
  unset S3_SECRET_ACCESS_KEY
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
unsigned="false"
[[ "${@: -1}" == *"no_sign_request=true"* ]] && unsigned="true"
if [[ "$unsigned" != "true" ]]; then
  echo "expected no_sign_request=true, got: $*" >&2
  exit 1
fi
if [[ "$1" == "lsf" ]]; then
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == []'
}
