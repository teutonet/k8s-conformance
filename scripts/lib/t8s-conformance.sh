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

# oldest_supported_minor <stable-version>
# Given the latest stable Kubernetes version (e.g. "v1.37.1", as in
# https://dl.k8s.io/release/stable.txt), prints the oldest minor
# (e.g. "1.35") cncf/k8s-conformance's verify-conformance bot still
# accepts submissions for: the latest minor and the two before it.
oldest_supported_minor() {
  local stable="${1#v}"
  local major="${stable%%.*}"
  local rest="${stable#*.}"
  local minor="${rest%%.*}"
  echo "${major}.$((minor - 2))"
}

# get_oldest_supported_minor
# Fetches the latest stable Kubernetes version and prints the oldest
# minor cncf/k8s-conformance's verify-conformance bot still accepts
# (see oldest_supported_minor). Returns 1 if the fetch fails.
get_oldest_supported_minor() {
  local stable
  if ! stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"; then
    return 1
  fi
  oldest_supported_minor "$stable"
}

# minor_is_older_than <minor> <other-minor>
# Succeeds if <minor> sorts strictly below <other-minor>.
minor_is_older_than() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# The bot's "required files" check looks at the PR's changed files, so an
# update that leaves PRODUCT.yaml byte-identical fails it. `version:` is
# the *product* version (not Kubernetes'), so we don't touch it; instead a
# YAML comment carries the submitted Kubernetes version, which guarantees
# PRODUCT.yaml differs on every update without changing the schema.
readonly T8S_PRODUCT_COMMENT_PREFIX='# kubernetes_version: '

# set_product_version_comment <full-version> <file>
# Adds or replaces the Kubernetes version comment in <file>.
set_product_version_comment() {
  local full_version="$1" file="$2"
  local comment_line="${T8S_PRODUCT_COMMENT_PREFIX}${full_version}"
  if grep -qF "$T8S_PRODUCT_COMMENT_PREFIX" "$file"; then
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line; do
      if [[ "$line" == "${T8S_PRODUCT_COMMENT_PREFIX}"* ]]; then
        echo "$comment_line"
      else
        echo "$line"
      fi
    done < "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    if [[ -n "$(tail -c1 "$file")" ]]; then
      echo >> "$file"
    fi
    echo "$comment_line" >> "$file"
  fi
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
