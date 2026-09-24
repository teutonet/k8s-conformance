#!/bin/bash

# Copyright 2023 CNCF.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Lists Kubernetes minor versions from S3 that have a clean (zero
# failures/errors) t8s conformance run and are not yet certified or
# submitted upstream in cncf/k8s-conformance. Prints a JSON array of
# minor versions (e.g. ["1.36","1.37"]) for use as a GitHub Actions
# matrix.
#
# Usage: list-t8s-conformance-candidates.sh <s3-bucket>
# Env: S3_ENDPOINT_URL (optional), S3_REGION (optional). If
# AWS_ACCESS_KEY_ID is unset, requests are made unsigned (--no-sign-request),
# for a publicly readable bucket.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/t8s-conformance.sh disable=SC1091
source "${SCRIPT_DIR}/lib/t8s-conformance.sh"

bucket="$1"

aws_args=()
[[ -n "${S3_ENDPOINT_URL:-}" ]] && aws_args+=(--endpoint-url "$S3_ENDPOINT_URL")
[[ -n "${S3_REGION:-}" ]] && aws_args+=(--region "$S3_REGION")
[[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && aws_args+=(--no-sign-request)

if ! s3_listing="$(aws s3 ls "${aws_args[@]}" "s3://${bucket}/")"; then
  echo "list-t8s-conformance-candidates: failed to list s3://${bucket}/" >&2
  exit 1
fi
mapfile -t minors < <(
  printf '%s\n' "$s3_listing" \
    | awk '{print $2}' \
    | grep -E '^v[0-9]+\.[0-9]+/$' \
    | sed -E 's#^v([0-9]+\.[0-9]+)/$#\1#'
)

candidates=()
for minor in "${minors[@]}"; do
  tmpdir="$(mktemp -d)"

  if ! aws s3 cp "${aws_args[@]}" "s3://${bucket}/v${minor}/junit_01.xml" "${tmpdir}/junit_01.xml" >/dev/null 2>&1; then
    echo "list-t8s-conformance-candidates: no junit_01.xml for v${minor}, skipping" >&2
    rm -rf "$tmpdir"
    continue
  fi

  if ! is_successful="$(junit_is_successful "${tmpdir}/junit_01.xml")"; then
    echo "list-t8s-conformance-candidates: malformed junit_01.xml for v${minor}, skipping" >&2
    rm -rf "$tmpdir"
    continue
  fi
  rm -rf "$tmpdir"

  if [[ "$is_successful" != "true" ]]; then
    echo "list-t8s-conformance-candidates: v${minor} has failures/errors, skipping" >&2
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

  candidates+=("$minor")
done

if [[ ${#candidates[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${candidates[@]}" | jq -R . | jq -s -c .
fi
