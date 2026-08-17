#!/usr/bin/env bash

set -euo pipefail

# Keep the version and checksum together. Dependabot does not manage this binary,
# so upgrades must update both values after checking the upstream release asset.
readonly XCODEGEN_VERSION="2.46.0"
readonly XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
readonly XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

: "${RUNNER_TEMP:?RUNNER_TEMP must be set by GitHub Actions}"
: "${GITHUB_PATH:?GITHUB_PATH must be set by GitHub Actions}"

readonly archive_path="${RUNNER_TEMP}/xcodegen-${XCODEGEN_VERSION}.zip"
readonly install_root="${RUNNER_TEMP}/xcodegen-${XCODEGEN_VERSION}"

curl --fail --silent --show-error --location \
  "${XCODEGEN_URL}" \
  --output "${archive_path}"

printf '%s  %s\n' "${XCODEGEN_SHA256}" "${archive_path}" | shasum -a 256 --check

mkdir -p "${install_root}"
unzip -q "${archive_path}" -d "${install_root}"

readonly xcodegen_bin="${install_root}/xcodegen/bin/xcodegen"
test -x "${xcodegen_bin}"
printf '%s\n' "${install_root}/xcodegen/bin" >> "${GITHUB_PATH}"

version_output="$("${xcodegen_bin}" --version)"
printf '%s\n' "${version_output}"
if [[ "${version_output}" != *"${XCODEGEN_VERSION}"* ]]; then
  echo "Expected XcodeGen ${XCODEGEN_VERSION}, got: ${version_output}" >&2
  exit 1
fi
