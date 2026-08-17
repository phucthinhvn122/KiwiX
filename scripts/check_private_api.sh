#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage: $0 --source <directory> | --binary <Mach-O>" >&2
  exit 2
}

[[ "$#" -eq 2 ]] || usage
mode="$1"
target="$2"

source_pattern='(PrivateFrameworks/|@selector\(_|Selector\("_|NSClassFromString\("(LSApplicationWorkspace|_UI|_WK)|perform\(Selector\("_|valueForKey:[[:space:]]*"_)'
binary_pattern='(LSApplicationWorkspace|_OBJC_CLASS_\$_LSApplicationWorkspace|/System/Library/PrivateFrameworks/)'

case "${mode}" in
  --source)
    test -d "${target}"
    matches="$(grep -RInE \
      --include='*.swift' \
      --include='*.m' \
      --include='*.mm' \
      --include='*.h' \
      --exclude-dir='.git' \
      --exclude-dir='build' \
      --exclude-dir='DerivedData' \
      --exclude='check_private_api.sh' \
      "${source_pattern}" "${target}" || true)"
    ;;
  --binary)
    test -f "${target}"
    matches="$({ nm -u "${target}" 2>/dev/null || true; strings "${target}"; } | grep -E "${binary_pattern}" || true)"
    ;;
  *)
    usage
    ;;
esac

if [[ -n "${matches}" ]]; then
  echo "Private API guard found forbidden references:" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "Private API guard passed (${mode} ${target})."
