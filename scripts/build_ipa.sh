#!/usr/bin/env bash

set -euo pipefail

readonly project="${PROJECT:-ExtensionBrowser.xcodeproj}"
readonly scheme="${SCHEME:-ExtensionBrowser}"
readonly configuration="${CONFIGURATION:-Release}"
readonly signing_mode="${SIGNING_MODE:-unsigned}"
readonly bundle_identifier="${BUNDLE_IDENTIFIER:-com.phucthinhvn122.KiwiX}"
readonly build_root="${BUILD_ROOT:-${PWD}/build/ipa}"
readonly output_dir="${OUTPUT_DIR:-${PWD}/artifacts/ipa}"
readonly archive_path="${build_root}/ExtensionBrowser.xcarchive"
readonly app_path="${archive_path}/Products/Applications/ExtensionBrowser.app"

require_value() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "${name} is required when SIGNING_MODE=${signing_mode}" >&2
    exit 2
  fi
}

rm -rf -- "${build_root}" "${output_dir}"
mkdir -p "${build_root}" "${output_dir}"

case "${signing_mode}" in
  unsigned)
    xcodebuild \
      -project "${project}" \
      -scheme "${scheme}" \
      -configuration "${configuration}" \
      -destination "generic/platform=iOS" \
      -archivePath "${archive_path}" \
      BUNDLE_IDENTIFIER="${bundle_identifier}" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      AD_HOC_CODE_SIGNING_ALLOWED=NO \
      clean archive

    test -d "${app_path}"
    staging_dir="$(mktemp -d "${build_root}/staging.XXXXXX")"
    trap 'rm -rf -- "${staging_dir}"' EXIT
    mkdir -p "${staging_dir}/Payload"
    ditto "${app_path}" "${staging_dir}/Payload/ExtensionBrowser.app"
    (
      cd "${staging_dir}"
      zip -qry "${output_dir}/ExtensionBrowser-Unsigned.ipa" Payload
    )
    unzip -t "${output_dir}/ExtensionBrowser-Unsigned.ipa"
    printf 'Unsigned IPA: %s\n' "${output_dir}/ExtensionBrowser-Unsigned.ipa"
    ;;
  development|ad-hoc)
    require_value APPLE_TEAM_ID
    require_value PROFILE_NAME
    require_value SIGNING_IDENTITY

    xcodebuild \
      -project "${project}" \
      -scheme "${scheme}" \
      -configuration "${configuration}" \
      -destination "generic/platform=iOS" \
      -archivePath "${archive_path}" \
      BUNDLE_IDENTIFIER="${bundle_identifier}" \
      PRODUCT_BUNDLE_IDENTIFIER="${bundle_identifier}" \
      CODE_SIGN_STYLE=Manual \
      DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
      PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME}" \
      CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
      clean archive

    readonly export_options="${build_root}/ExportOptions.plist"
    /usr/bin/python3 scripts/ci/generate-export-options.py \
      --output "${export_options}" \
      --method "${signing_mode}" \
      --team-id "${APPLE_TEAM_ID}" \
      --bundle-id "${bundle_identifier}" \
      --profile-name "${PROFILE_NAME}"
    plutil -lint "${export_options}"

    readonly export_dir="${build_root}/export"
    xcodebuild -exportArchive \
      -archivePath "${archive_path}" \
      -exportPath "${export_dir}" \
      -exportOptionsPlist "${export_options}"

    shopt -s nullglob
    ipa_files=("${export_dir}"/*.ipa)
    if [[ "${#ipa_files[@]}" -ne 1 ]]; then
      echo "Expected exactly one signed IPA, found ${#ipa_files[@]}" >&2
      exit 1
    fi
    cp "${ipa_files[0]}" "${output_dir}/ExtensionBrowser.ipa"
    unzip -t "${output_dir}/ExtensionBrowser.ipa"
    codesign --verify --deep --strict "${app_path}"
    printf 'Signed IPA: %s\n' "${output_dir}/ExtensionBrowser.ipa"
    ;;
  *)
    echo "SIGNING_MODE must be unsigned, development, or ad-hoc" >&2
    exit 2
    ;;
esac

bash scripts/check_private_api.sh --binary "${app_path}/ExtensionBrowser"
