#!/usr/bin/env bash

set -euo pipefail

readonly project="${PROJECT:-ExtensionBrowser.xcodeproj}"
readonly scheme="${SCHEME:-ExtensionBrowser}"
readonly destination="${DESTINATION:?DESTINATION must identify a bootable iOS Simulator}"
readonly derived_data="${DERIVED_DATA:-${PWD}/build/bench}"
readonly result_bundle="${RESULT_BUNDLE_PATH:-${PWD}/build/Benchmarks.xcresult}"
readonly bundle_identifier="${BUNDLE_IDENTIFIER:-com.phucthinhvn122.KiwiX}"

rm -rf -- "${result_bundle}"
mkdir -p "$(dirname "${result_bundle}")"

xcodebuild \
  -project "${project}" \
  -scheme "${scheme}" \
  -destination "${destination}" \
  -destination-timeout 120 \
  -derivedDataPath "${derived_data}" \
  -resultBundlePath "${result_bundle}" \
  BUNDLE_IDENTIFIER="${bundle_identifier}" \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ExtensionBrowserTests/M0InfrastructureBenchmarks \
  test

test -d "${result_bundle}"
echo "Benchmark result bundle: ${result_bundle}"
