#!/bin/bash

[[ "${RUNNER_DEBUG:-}" == 1 ]] && set -x
[[ -o xtrace ]] && export RUNNER_DEBUG=1

# Stages a vX.Y/t8s submission directory in the current directory
# (expected to be a cncf/k8s-conformance checkout), using the highest
# existing older v*/t8s directory as a template and fetching this
# version's e2e.log/junit_01.xml from S3. The destination directory is
# always minor-only (vX.Y/t8s) -- that's cncf/k8s-conformance's own fixed
# convention, conformance is certified per minor line, not per patch --
# but the README's Kubernetes version sentence gets the full patch
# version, since that's what's actually available now. If vX.Y/t8s
# already exists (updating an already-certified minor with a newer
# patch), its own files are refreshed in place instead of copying a
# template over them.
#
# Usage: build-t8s-submission.sh <full-version> <s3-bucket>
# <full-version> is the full X.Y.Z version (e.g. "1.36.2"); the minor
# (e.g. "1.36") is derived from it for the destination directory.
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

full_version="$1"
bucket="$2"
minor="${full_version%.*}"

existing_versions=()
for product_yaml in v*/t8s/PRODUCT.yaml; do
  [[ -f "$product_yaml" ]] || continue
  version_dir="${product_yaml%%/t8s/PRODUCT.yaml}"
  existing_versions+=("${version_dir#v}")
done

if [[ ${#existing_versions[@]} -eq 0 ]]; then
  echo "build-t8s-submission: no existing v*/t8s directory found to use as a template" >&2
  exit 1
fi

if ! template_version="$(highest_version_below "$minor" "${existing_versions[@]}")"; then
  # No existing t8s submission is for an older minor than this one --
  # e.g. backfilling an older Kubernetes release after a newer one was
  # already certified. Any existing t8s dir is a fine structural
  # template regardless of version direction (PRODUCT.yaml is generic,
  # and the README's version sentence gets fully replaced), so fall
  # back to the highest one overall.
  template_version="$(printf '%s\n' "${existing_versions[@]}" | sort -V | tail -n1)"
fi
template_dir="v${template_version}/t8s"
target_dir="v${minor}/t8s"

mkdir -p "$target_dir"
if [[ "$template_version" != "$minor" ]]; then
  # Only copy when the template is a different directory -- updating an
  # already-certified minor in place picks itself as the fallback
  # template (nothing else to copy from), and `cp` refuses to copy a
  # file onto itself.
  cp "${template_dir}/PRODUCT.yaml" "${target_dir}/PRODUCT.yaml"
  cp "${template_dir}/README.md" "${target_dir}/README.md"
fi
set_readme_kubernetes_version "$full_version" "${target_dir}/README.md"
set_t8s_version_marker "$full_version" "${target_dir}/README.md"
set_product_version_comment "$full_version" "${target_dir}/PRODUCT.yaml"

remote="s3,provider=Ceph,endpoint='${S3_ENDPOINT_URL:-}',region=${S3_REGION:-}"
if [[ -n "${S3_ACCESS_KEY_ID:-}" ]]; then
  remote="${remote},access_key_id=${S3_ACCESS_KEY_ID},secret_access_key=${S3_SECRET_ACCESS_KEY:-}"
else
  remote="${remote},no_sign_request=true"
fi

rclone copyto ":${remote}:${bucket}/v${full_version}/e2e.log" "${target_dir}/e2e.log"
rclone copyto ":${remote}:${bucket}/v${full_version}/junit_01.xml" "${target_dir}/junit_01.xml"

echo "$target_dir"
