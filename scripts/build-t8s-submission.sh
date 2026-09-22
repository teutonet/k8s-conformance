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

# Stages a new vX.Y/t8s submission directory in the current directory
# (expected to be a cncf/k8s-conformance checkout), using the highest
# existing older v*/t8s directory as a template and fetching this
# version's e2e.log/junit_01.xml from S3.
#
# Usage: build-t8s-submission.sh <minor-version> <s3-bucket>
# Env: S3_ENDPOINT_URL (optional), S3_REGION (optional)

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/t8s-conformance.sh disable=SC1091
source "${SCRIPT_DIR}/lib/t8s-conformance.sh"

minor="$1"
bucket="$2"

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

template_version="$(highest_version_below "$minor" "${existing_versions[@]}")"
template_dir="v${template_version}/t8s"
target_dir="v${minor}/t8s"

mkdir -p "$target_dir"
cp "${template_dir}/PRODUCT.yaml" "${target_dir}/PRODUCT.yaml"
cp "${template_dir}/README.md" "${target_dir}/README.md"
set_readme_kubernetes_version "$minor" "${target_dir}/README.md"

aws_args=()
[[ -n "${S3_ENDPOINT_URL:-}" ]] && aws_args+=(--endpoint-url "$S3_ENDPOINT_URL")
[[ -n "${S3_REGION:-}" ]] && aws_args+=(--region "$S3_REGION")

aws s3 cp "${aws_args[@]}" "s3://${bucket}/v${minor}/e2e.log" "${target_dir}/e2e.log"
aws s3 cp "${aws_args[@]}" "s3://${bucket}/v${minor}/junit_01.xml" "${target_dir}/junit_01.xml"

echo "$target_dir"
