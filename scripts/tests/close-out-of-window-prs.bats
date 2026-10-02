#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../close-out-of-window-prs.sh"
  STUB_BIN="$(mktemp -d)"
  CLOSED_LOG="${STUB_BIN}/closed.log"
  export CLOSED_LOG

  # Latest stable is v1.37.1 -> supported window is 1.35..1.37.
  cat > "${STUB_BIN}/curl" <<'EOF'
#!/bin/bash
echo "v1.37.1"
EOF
  chmod +x "${STUB_BIN}/curl"

  # Open bot PRs: 1.33 (out of window), 1.36 (in window), plus an
  # unrelated branch that must be ignored.
  cat > "${STUB_BIN}/gh" <<'EOF'
#!/bin/bash
set -o errexit -o nounset -o pipefail
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  cat <<'LIST'
4461 t8s-conformance-v1.33
4460 t8s-conformance-v1.36
4999 some-other-branch
LIST
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "close" ]]; then
  echo "$3" >> "$CLOSED_LOG"
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

@test "close-out-of-window-prs: closes only the PR whose minor fell out of the window" {
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT"
  [ "$status" -eq 0 ]
  run cat "$CLOSED_LOG"
  [ "$output" = "4461" ]
}

@test "close-out-of-window-prs: does nothing when every PR is in the window" {
  cat > "${STUB_BIN}/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  echo "4460 t8s-conformance-v1.36"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$CLOSED_LOG" ]
}

@test "close-out-of-window-prs: keeps going but exits nonzero when one close fails" {
  cat > "${STUB_BIN}/gh" <<'EOF'
#!/bin/bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '4461 t8s-conformance-v1.33\n4462 t8s-conformance-v1.34\n'
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "close" ]]; then
  [[ "$3" == "4461" ]] && exit 1
  echo "$3" >> "$CLOSED_LOG"
  exit 0
fi
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT"
  [ "$status" -ne 0 ]
  run cat "$CLOSED_LOG"
  [ "$output" = "4462" ]
}

@test "close-out-of-window-prs: exits nonzero when the stable version can't be fetched" {
  printf '#!/bin/bash\nexit 22\n' > "${STUB_BIN}/curl"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "close-out-of-window-prs: exits nonzero when listing PRs fails" {
  printf '#!/bin/bash\nexit 1\n' > "${STUB_BIN}/gh"
  PATH="${STUB_BIN}:${PATH}" run "$SCRIPT"
  [ "$status" -ne 0 ]
}
