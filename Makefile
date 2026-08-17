PROJECT ?= ExtensionBrowser.xcodeproj
SCHEME ?= ExtensionBrowser
CONFIGURATION ?= Debug
DERIVED_DATA ?= build/DerivedData
DESTINATION ?= generic/platform=iOS Simulator
BUNDLE_IDENTIFIER ?= com.phucthinhvn122.KiwiX
RESULT_BUNDLE_PATH ?= build/Benchmarks.xcresult
TEST_RESULT_BUNDLE_PATH ?= build/Tests.xcresult

.PHONY: generate build test ipa bench private-api clean

generate:
	xcodegen generate --spec project.yml

build: generate private-api
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		BUNDLE_IDENTIFIER="$(BUNDLE_IDENTIFIER)" \
		CODE_SIGNING_ALLOWED=NO \
		clean build

test: generate private-api
	rm -rf -- "$(TEST_RESULT_BUNDLE_PATH)"
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-destination "$(DESTINATION)" \
		-destination-timeout 120 \
		-derivedDataPath "$(DERIVED_DATA)" \
		-resultBundlePath "$(TEST_RESULT_BUNDLE_PATH)" \
		-test-timeouts-enabled YES \
		-default-test-execution-time-allowance 60 \
		-maximum-test-execution-time-allowance 120 \
		BUNDLE_IDENTIFIER="$(BUNDLE_IDENTIFIER)" \
		CODE_SIGNING_ALLOWED=NO \
		-parallel-testing-enabled NO \
		test

ipa: generate private-api
	BUNDLE_IDENTIFIER="$(BUNDLE_IDENTIFIER)" bash scripts/build_ipa.sh

bench: generate private-api
	RESULT_BUNDLE_PATH="$(RESULT_BUNDLE_PATH)" \
	DESTINATION="$(DESTINATION)" \
	BUNDLE_IDENTIFIER="$(BUNDLE_IDENTIFIER)" \
		bash scripts/bench.sh

private-api:
	bash scripts/check_private_api.sh --source .

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" clean || true
	rm -rf -- "$(DERIVED_DATA)"
