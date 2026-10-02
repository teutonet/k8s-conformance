#!/bin/bash

[[ "${RUNNER_DEBUG:-}" == 1 ]] && set -x
[[ -o xtrace ]] && export RUNNER_DEBUG=1

# Lists full Kubernetes versions from S3 (bucket layout: vX.Y.Z/) that
# have a clean (zero failures/errors) t8s conformance run, and whose
# minor (X.Y) either isn't certified upstream in cncf/k8s-conformance
# yet, or is certified with an older patch than what's in the bucket
# (an update). A minor with an open PR of ours is only re-listed when the
# bucket has a strictly newer patch than the PR carries, so the PR gets
# refreshed in place. Minors outside the supported release window are
# skipped. If a minor has multiple patch prefixes in the bucket, only
# the highest patch is considered. Prints a JSON array of objects
# (e.g. [{"version":"1.36.2","update":false},{"version":"1.35.5","update":true}])
# for use as a GitHub Actions matrix.
#
# Usage: list-t8s-conformance-candidates.sh <s3-bucket>
# Env: S3_ENDPOINT_URL, S3_REGION. If S3_ACCESS_KEY_ID is unset, requests
# are made unsigned (no_sign_request), for a publicly readable bucket.
# Uses rclone rather than the aws CLI: the aws CLI's client-side bucket
# name validation rejects Ceph-style "tenant:bucket" names outright, with
# no override; rclone handles them fine.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/t8s-conformance.sh disable=SC1091
source "${SCRIPT_DIR}/lib/t8s-conformance.sh"

bucket="$1"

remote="s3,provider=Ceph,endpoint='${S3_ENDPOINT_URL:-}',region=${S3_REGION:-}"
if [[ -n "${S3_ACCESS_KEY_ID:-}" ]]; then
  remote="${remote},access_key_id=${S3_ACCESS_KEY_ID},secret_access_key=${S3_SECRET_ACCESS_KEY:-}"
else
  remote="${remote},no_sign_request=true"
fi

if ! s3_listing="$(rclone lsf --dirs-only ":${remote}:${bucket}/")"; then
  echo "list-t8s-conformance-candidates: failed to list ${bucket}/" >&2
  exit 1
fi
mapfile -t full_versions < <(
  printf '%s\n' "$s3_listing" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+/$' \
    | sed -E 's#^v([0-9]+\.[0-9]+\.[0-9]+)/$#\1#'
)

# A minor can have multiple patch prefixes in the bucket (e.g. an
# upgraded smoke-test cluster leaving old results behind); only the
# highest patch per minor is worth considering.
declare -A best_version_for_minor
for full_version in "${full_versions[@]}"; do
  minor="${full_version%.*}"
  current_best="${best_version_for_minor[$minor]:-}"
  if [[ -z "$current_best" ]] || [[ "$(printf '%s\n%s\n' "$current_best" "$full_version" | sort -V | tail -n1)" == "$full_version" ]]; then
    best_version_for_minor[$minor]="$full_version"
  fi
done

# cncf/k8s-conformance's verify-conformance bot rejects (and never runs
# its other checks on) submissions for minors older than the latest
# stable release minus two, so those can never pass -- don't open PRs
# for them.
if ! oldest_supported="$(get_oldest_supported_minor)"; then
  echo "list-t8s-conformance-candidates: failed to fetch the latest stable Kubernetes version" >&2
  exit 1
fi

candidates=()
for minor in "${!best_version_for_minor[@]}"; do
  full_version="${best_version_for_minor[$minor]}"

  if minor_is_older_than "$minor" "$oldest_supported"; then
    echo "list-t8s-conformance-candidates: v${minor} is older than the oldest supported release v${oldest_supported}, skipping" >&2
    continue
  fi

  tmpdir="$(mktemp -d)"

  if ! rclone copyto ":${remote}:${bucket}/v${full_version}/junit_01.xml" "${tmpdir}/junit_01.xml" >/dev/null 2>&1; then
    echo "list-t8s-conformance-candidates: no junit_01.xml for v${full_version}, skipping" >&2
    rm -rf "$tmpdir"
    continue
  fi

  if ! is_successful="$(junit_is_successful "${tmpdir}/junit_01.xml")"; then
    echo "list-t8s-conformance-candidates: malformed junit_01.xml for v${full_version}, skipping" >&2
    rm -rf "$tmpdir"
    continue
  fi
  rm -rf "$tmpdir"

  if [[ "$is_successful" != "true" ]]; then
    echo "list-t8s-conformance-candidates: v${full_version} has failures/errors, skipping" >&2
    continue
  fi

  is_update="false"
  readme_tmpdir="$(mktemp -d)"
  if gh api "repos/cncf/k8s-conformance/contents/v${minor}/t8s/README.md" --jq '.content' 2>/dev/null | base64 -d > "${readme_tmpdir}/README.md" 2>/dev/null; then
    certified_version="$(get_t8s_version_marker "${readme_tmpdir}/README.md")" || {
      # Pre-automation submission with no marker yet -- fall back to the
      # prose sentence once. Every future update adds the marker, so
      # this path only ever fires for entries this automation hasn't
      # touched yet.
      # TODO: v1.35 is the only entry that ever needed this (predates
      # the marker). Remove this fallback once its first update PR
      # (adding the marker) is merged upstream.
      certified_version="$(grep -oE 'Kubernetes [0-9]+\.[0-9]+\.[0-9]+' "${readme_tmpdir}/README.md" | head -n1 | awk '{print $2}' || true)"
    }
    rm -rf "$readme_tmpdir"
    if [[ -z "$certified_version" ]]; then
      echo "list-t8s-conformance-candidates: v${minor} already certified upstream but couldn't determine its patch version, skipping" >&2
      continue
    fi
    if [[ "$certified_version" == "$full_version" ]] || [[ "$(printf '%s\n%s\n' "$certified_version" "$full_version" | sort -V | tail -n1)" == "$certified_version" ]]; then
      echo "list-t8s-conformance-candidates: v${minor} already certified with v${certified_version} (not older than v${full_version}), skipping" >&2
      continue
    fi
    echo "list-t8s-conformance-candidates: v${minor} certified with older v${certified_version}, will submit an update to v${full_version}" >&2
    is_update="true"
  else
    rm -rf "$readme_tmpdir"
  fi

  # An open PR is only worth touching if it's ours (identified by its
  # branch name) *and* the bucket has a strictly newer patch than the one
  # it carries -- merging can take longer than a new patch release, so
  # the PR gets refreshed in place instead of going stale.
  if ! open_branches="$(gh pr list --repo cncf/k8s-conformance --state open --search "v${minor}/t8s in:title" --json headRefName --jq '.[].headRefName')"; then
    echo "list-t8s-conformance-candidates: failed to check open PRs for v${minor}, skipping" >&2
    continue
  fi
  if [[ -n "$open_branches" ]]; then
    pr_branch="t8s-conformance-v${minor}"
    if ! grep -qxF "$pr_branch" <<<"$open_branches"; then
      echo "list-t8s-conformance-candidates: v${minor} has an open PR that isn't ours, skipping" >&2
      continue
    fi
    pr_tmpdir="$(mktemp -d)"
    if gh api "repos/teutonet/k8s-conformance/contents/v${minor}/t8s/README.md?ref=${pr_branch}" --jq '.content' 2>/dev/null | base64 -d > "${pr_tmpdir}/README.md" 2>/dev/null; then
      pr_version="$(get_t8s_version_marker "${pr_tmpdir}/README.md" || true)"
    else
      pr_version=""
    fi
    rm -rf "$pr_tmpdir"
    if [[ -z "$pr_version" ]]; then
      echo "list-t8s-conformance-candidates: v${minor} has an open PR but its version couldn't be read, skipping" >&2
      continue
    fi
    if [[ "$pr_version" == "$full_version" ]] || [[ "$(printf '%s\n%s\n' "$pr_version" "$full_version" | sort -V | tail -n1)" == "$pr_version" ]]; then
      echo "list-t8s-conformance-candidates: v${minor} open PR already carries v${pr_version} (not older than v${full_version}), skipping" >&2
      continue
    fi
    echo "list-t8s-conformance-candidates: v${minor} open PR carries older v${pr_version}, will refresh it to v${full_version}" >&2
  fi

  candidates+=("{\"version\":\"${full_version}\",\"update\":${is_update}}")
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${candidates[@]}" | jq -s -c .
fi
