#!/bin/bash

# Lists full Kubernetes versions from S3 (bucket layout: vX.Y.Z/) that
# have a clean (zero failures/errors) t8s conformance run, whose minor
# (X.Y) is not yet certified or submitted upstream in
# cncf/k8s-conformance. If a minor has multiple patch prefixes in the
# bucket, only the highest patch is considered. Prints a JSON array of
# full versions (e.g. ["1.36.2","1.37.0"]) for use as a GitHub Actions
# matrix.
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

candidates=()
for minor in "${!best_version_for_minor[@]}"; do
  full_version="${best_version_for_minor[$minor]}"
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

  if gh api "repos/cncf/k8s-conformance/contents/v${minor}/t8s/PRODUCT.yaml" >/dev/null 2>&1; then
    echo "list-t8s-conformance-candidates: v${minor} already certified upstream, skipping" >&2
    continue
  fi

  if ! open_prs="$(gh pr list --repo cncf/k8s-conformance --state open --search "v${minor}/t8s in:title" --json number --jq 'length')"; then
    echo "list-t8s-conformance-candidates: failed to check open PRs for v${minor}, skipping" >&2
    continue
  fi
  if [[ "$open_prs" != "0" ]]; then
    echo "list-t8s-conformance-candidates: v${minor} already has an open PR upstream, skipping" >&2
    continue
  fi

  candidates+=("$full_version")
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${candidates[@]}" | jq -R . | jq -s -c .
fi
