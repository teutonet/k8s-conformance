#!/bin/bash

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

# The full k8s version we last submitted lives in a hidden HTML comment
# in the README (GitHub doesn't render HTML comments), as a small JSON
# blob -- typed, jq-parseable, no regex-over-prose needed. Older
# pre-automation submissions won't have this marker; callers fall back
# to the "Kubernetes X.Y.Z" prose sentence for those, once, until this
# marker gets added on their first update.
readonly T8S_VERSION_MARKER_PREFIX='<!-- t8s-conformance-metadata: '

# set_t8s_version_marker <full-version> <file>
# Adds or replaces the hidden version marker comment in <file>.
set_t8s_version_marker() {
  local full_version="$1" file="$2"
  local marker_json
  marker_json="$(jq -cn --arg v "$full_version" '{kubernetes_version: $v}')"
  local marker_line="${T8S_VERSION_MARKER_PREFIX}${marker_json} -->"
  if grep -qF "$T8S_VERSION_MARKER_PREFIX" "$file"; then
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line; do
      if [[ "$line" == "${T8S_VERSION_MARKER_PREFIX}"* ]]; then
        echo "$marker_line"
      else
        echo "$line"
      fi
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '\n%s\n' "$marker_line" >> "$file"
  fi
}

# get_t8s_version_marker <file>
# Prints the full version from the hidden marker comment in <file>.
# Returns 1 if no marker is present (e.g. a pre-automation submission).
get_t8s_version_marker() {
  local file="$1"
  local line
  if ! line="$(grep -F "$T8S_VERSION_MARKER_PREFIX" "$file")"; then
    return 1
  fi
  local marker_json="${line#"$T8S_VERSION_MARKER_PREFIX"}"
  marker_json="${marker_json% -->}"
  jq -r '.kubernetes_version' <<<"$marker_json"
}
