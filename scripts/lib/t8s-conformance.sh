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

# Shared helpers for the t8s conformance submission scripts. Meant to be
# sourced, not executed directly.

# junit_is_successful <path-to-junit-xml>
# Prints "true" if the top-level <testsuites> element has errors="0" and
# failures="0", "false" otherwise. Returns 1 if the file is missing or
# has no <testsuites> root element.
junit_is_successful() {
  local junit_file="$1"
  if [[ ! -f "$junit_file" ]]; then
    echo "junit_is_successful: file not found: $junit_file" >&2
    return 1
  fi
  local root_line
  if ! root_line="$(grep -m1 '<testsuites ' "$junit_file")"; then
    echo "junit_is_successful: no <testsuites> element in $junit_file" >&2
    return 1
  fi
  if [[ "$root_line" == *'errors="0"'* && "$root_line" == *'failures="0"'* ]]; then
    echo "true"
  else
    echo "false"
  fi
}

# highest_version_below <target> <version...>
# Given a target dotted version (e.g. "1.36") and a list of dotted
# versions, prints the highest one that sorts strictly below the target
# using version-aware comparison. Returns 1 and prints nothing if none
# qualify.
highest_version_below() {
  local target="$1"
  shift
  local best=""
  local v
  for v in "$@"; do
    if [[ "$(printf '%s\n%s\n' "$v" "$target" | sort -V | tail -n1)" == "$target" && "$v" != "$target" ]]; then
      if [[ -z "$best" || "$(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -n1)" == "$v" ]]; then
        best="$v"
      fi
    fi
  done
  if [[ -z "$best" ]]; then
    return 1
  fi
  echo "$best"
}

# set_readme_kubernetes_version <new-minor> <file>
# In-place rewrites any "Kubernetes X.Y" or "Kubernetes X.Y.Z" occurrence
# in <file> to "Kubernetes <new-minor>", dropping any patch version.
set_readme_kubernetes_version() {
  local new="$1" file="$2"
  sed -i -E "s/Kubernetes [0-9]+\.[0-9]+(\.[0-9]+)?/Kubernetes ${new}/g" "$file"
}
