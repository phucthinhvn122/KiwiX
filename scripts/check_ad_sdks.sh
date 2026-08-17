#!/usr/bin/env bash

set -euo pipefail

target="${1:-.}"
test -d "${target}"

pattern='(GoogleMobileAds|GADBannerView|GADInterstitialAd|GADRewardedAd|AppLovinSDK|MAAdView|IronSource|UnityAds|FBAudienceNetwork|VungleSDK|Chartboost|StartAppSDK|googlesyndication\.com|doubleclick\.net)'

matches="$(grep -RInE \
  --include='*.swift' \
  --include='*.m' \
  --include='*.mm' \
  --include='*.h' \
  --include='*.yml' \
  --include='*.yaml' \
  --include='Package.swift' \
  --exclude-dir='.git' \
  --exclude-dir='build' \
  --exclude-dir='DerivedData' \
  --exclude='check_ad_sdks.sh' \
  "${pattern}" "${target}" || true)"

if [[ -n "${matches}" ]]; then
  echo "Advertising SDK guard found forbidden references:" >&2
  printf '%s\n' "${matches}" >&2
  exit 1
fi

echo "Advertising SDK guard passed (${target})."
