#!/bin/bash

[[ "${RUNNER_DEBUG:-}" == 1 ]] && set -x
[[ -o xtrace ]] && export RUNNER_DEBUG=1

# Closes our open PRs in cncf/k8s-conformance whose Kubernetes minor has
# fallen out of the supported release window (latest stable minus two).
# The verify-conformance bot can't accept those anymore, and merging can
# take longer than the window moves.
#
# Usage: close-out-of-window-prs.sh
# Env: GH_TOKEN must belong to the account that authored the PRs.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/t8s-conformance.sh disable=SC1091
source "${SCRIPT_DIR}/lib/t8s-conformance.sh"

readonly BOT_USER="bot-TeutoNet"
readonly BRANCH_PREFIX="t8s-conformance-v"

if ! oldest_supported="$(get_oldest_supported_minor)"; then
  echo "close-out-of-window-prs: failed to fetch the latest stable Kubernetes version" >&2
  exit 1
fi

if ! open_prs="$(gh pr list --repo cncf/k8s-conformance --state open --author "$BOT_USER" --json number,headRefName --jq '.[] | "\(.number) \(.headRefName)"')"; then
  echo "close-out-of-window-prs: failed to list open PRs" >&2
  exit 1
fi

failed=0
while read -r number branch; do
  [[ -n "${number:-}" ]] || continue
  [[ "$branch" == "${BRANCH_PREFIX}"* ]] || continue
  minor="${branch#"$BRANCH_PREFIX"}"
  minor_is_older_than "$minor" "$oldest_supported" || continue

  echo "close-out-of-window-prs: closing #${number} (v${minor} is older than the oldest supported release v${oldest_supported})" >&2
  if ! gh pr close "$number" --repo cncf/k8s-conformance --comment "Closing: v${minor} is no longer a supported Kubernetes release (the oldest currently supported is v${oldest_supported}), so this submission can't be accepted anymore."; then
    echo "close-out-of-window-prs: failed to close #${number}" >&2
    failed=1
  fi
done <<<"$open_prs"

exit "$failed"
