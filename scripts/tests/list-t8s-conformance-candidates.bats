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
v1.35.6/
v1.36.2/
v1.37.0/
LIST
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  case "$src" in
    *v1.35.6/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *v1.36.2/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *v1.37.0/junit_01.xml) echo '<testsuites errors="0" failures="3"></testsuites>' > "$dest" ;;
    *) echo "unexpected rclone copyto source: $src" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  # By default: 1.35 already certified with the same patch as the
  # bucket (README marker "1.35.6") -> not an update; 1.36 never
  # certified (no README) -> a plain new candidate.
  cat > "${STUB_BIN}/gh" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "api" && "$2" == "repos/cncf/k8s-conformance/contents/v1.35/t8s/README.md" ]]; then
  content="$(echo -n '<!-- t8s-conformance-metadata: {"kubernetes_version":"1.35.6"} -->' | base64 -w0)"
  echo "$content"
  exit 0
fi
if [[ "$1" == "api" && "$2" == repos/cncf/k8s-conformance/contents/v1.36/t8s/README.md ]]; then
  echo "not found" >&2
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

  # Latest stable is v1.37.1 -> supported window is 1.35..1.37.
  cat > "${STUB_BIN}/curl" <<'EOF'
#!/bin/bash
echo "v1.37.1"
EOF
  chmod +x "${STUB_BIN}/curl"
}

teardown() {
  rm -rf "$STUB_BIN"
}

@test "list-t8s-conformance-candidates: keeps the clean, uncertified minor as a non-update candidate" {
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == [{"version":"1.36.2","update":false}]'
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
v1.35.6/
v1.36.2/
LIST
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  case "$src" in
    *v1.35.6/junit_01.xml) echo '<malformed/>' > "$dest" ;;
    *v1.36.2/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *) echo "unexpected rclone copyto source: $src" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == [{"version":"1.36.2","update":false}]'
}

@test "list-t8s-conformance-candidates: keeps only the highest patch when a minor has multiple prefixes" {
  # Bucket has two patch prefixes for the same minor: 1.36.1 (older,
  # must never be fetched) and 1.36.2 (newer, clean, not certified ->
  # the only one that should be used).
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  cat <<'LIST'
v1.36.1/
v1.36.2/
LIST
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  src="$2"
  dest="$3"
  case "$src" in
    *v1.36.2/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$dest" ;;
    *v1.36.1/junit_01.xml) echo "must not fetch the older patch" >&2; exit 1 ;;
    *) echo "unexpected rclone copyto source: $src" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/rclone"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == [{"version":"1.36.2","update":false}]'
}

@test "list-t8s-conformance-candidates: submits an update when the README marker shows an older certified patch" {
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  echo 'v1.35.5/'
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  case "$2" in
    *v1.35.5/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$3" ;;
    *) echo "unexpected rclone copyto source: $2" >&2; exit 1 ;;
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
if [[ "$1" == "api" && "$2" == "repos/cncf/k8s-conformance/contents/v1.35/t8s/README.md" ]]; then
  content="$(echo -n '<!-- t8s-conformance-metadata: {"kubernetes_version":"1.35.2"} -->' | base64 -w0)"
  echo "$content"
  exit 0
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
  echo "$output" | tail -n1 | jq -e '. == [{"version":"1.35.5","update":true}]'
}

@test "list-t8s-conformance-candidates: skips when the README marker shows the same or newer certified patch" {
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  echo 'v1.36.2/'
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  case "$2" in
    *v1.36.2/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$3" ;;
    *) echo "unexpected rclone copyto source: $2" >&2; exit 1 ;;
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
if [[ "$1" == "api" && "$2" == "repos/cncf/k8s-conformance/contents/v1.36/t8s/README.md" ]]; then
  content="$(echo -n '<!-- t8s-conformance-metadata: {"kubernetes_version":"1.36.5"} -->' | base64 -w0)"
  echo "$content"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == []'
}

@test "list-t8s-conformance-candidates: falls back to prose parsing for a pre-automation README with no marker" {
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  echo 'v1.35.5/'
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  case "$2" in
    *v1.35.5/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$3" ;;
    *) echo "unexpected rclone copyto source: $2" >&2; exit 1 ;;
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
if [[ "$1" == "api" && "$2" == "repos/cncf/k8s-conformance/contents/v1.35/t8s/README.md" ]]; then
  content="$(echo -n 'Tested on a Kubernetes 1.35.2 cluster.' | base64 -w0)"
  echo "$content"
  exit 0
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
  echo "$output" | tail -n1 | jq -e '. == [{"version":"1.35.5","update":true}]'
}

@test "list-t8s-conformance-candidates: skips a certified minor when neither marker nor prose can be parsed" {
  cat > "${STUB_BIN}/rclone" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  echo 'v1.35.5/'
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  case "$2" in
    *v1.35.5/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$3" ;;
    *) echo "unexpected rclone copyto source: $2" >&2; exit 1 ;;
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
if [[ "$1" == "api" && "$2" == "repos/cncf/k8s-conformance/contents/v1.35/t8s/README.md" ]]; then
  content="$(echo -n 'No version information in this README at all.' | base64 -w0)"
  echo "$content"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == []'
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

@test "list-t8s-conformance-candidates: skips a minor older than the oldest supported release" {
  # Latest stable is v1.37.1 (curl stub), so 1.35 is the oldest the
  # verify-conformance bot accepts; 1.33 must never be fetched or even
  # looked up upstream, 1.36 stays a normal candidate.
  cat > "${STUB_BIN}/rclone" <<'EOS'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "lsf" ]]; then
  cat <<'LIST'
v1.33.11/
v1.36.2/
LIST
  exit 0
fi
if [[ "$1" == "copyto" ]]; then
  case "$2" in
    *v1.36.2/junit_01.xml) echo '<testsuites errors="0" failures="0"></testsuites>' > "$3" ;;
    *v1.33.11/junit_01.xml) echo "must not fetch an out-of-window minor" >&2; exit 1 ;;
    *) echo "unexpected rclone copyto source: $2" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "unexpected rclone invocation: $*" >&2
exit 1
EOS
  chmod +x "${STUB_BIN}/rclone"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -eq 0 ]
  echo "$output" | tail -n1 | jq -e '. == [{"version":"1.36.2","update":false}]'
}

@test "list-t8s-conformance-candidates: exits nonzero when the latest stable version can't be fetched" {
  cat > "${STUB_BIN}/curl" <<'EOS'
#!/bin/bash
exit 22
EOS
  chmod +x "${STUB_BIN}/curl"

  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT" "fake-bucket"
  [ "$status" -ne 0 ]
}
