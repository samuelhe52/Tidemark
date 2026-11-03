.DEFAULT_GOAL := help

# Configuration
PROJECT ?= Tidemark.xcodeproj
SCHEME ?= Tidemark
APP_NAME ?= Tidemark
CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS
KIT_PATH ?= Packages/TidemarkKit
APP_PATH = $(shell xcodebuild -quiet -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination "$(DESTINATION)" -showBuildSettings -json | /usr/bin/python3 -c 'import json, sys; data = json.load(sys.stdin); item = next(entry for entry in data if entry.get("target") == "$(APP_NAME)"); settings = item["buildSettings"]; print(settings["TARGET_BUILD_DIR"] + "/" + settings["FULL_PRODUCT_NAME"])')

# Build and Run
.PHONY: build
build: ## Build the app
	@echo "Building $(SCHEME)..."
	@set -o pipefail; NSUnbufferedIO=YES xcodebuild -quiet -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination "$(DESTINATION)" -allowProvisioningUpdates build 2>&1 | xcbeautify --disable-logging
	@echo "Build completed."

.PHONY: build-kit
build-kit: ## Build the TidemarkKit package on its own
	swift build --package-path $(KIT_PATH)

.PHONY: run
run: build ## Build, then relaunch the app
	@$(MAKE) --no-print-directory launch

.PHONY: launch
launch: ## Relaunch the last built app, without building
	@app_path="$(APP_PATH)"; \
	[ -d "$$app_path" ] || { echo "No built app at $$app_path. Run make run first."; exit 1; }; \
	newer=$$(find Sources $(KIT_PATH)/Sources -name '*.swift' -newer "$$app_path/Contents/MacOS" | head -3); \
	[ -z "$$newer" ] || echo "Warning: sources are newer than the built app, e.g. $$newer"; \
	pkill -f "$$app_path/Contents/MacOS/" && sleep 1; \
	open -n "$$app_path"

.PHONY: test
test: ## Run the engine and data package tests
	swift test --package-path $(KIT_PATH)

# Release
.PHONY: dmg
dmg: ## Build a signed, notarized DMG with the Xcode account (VERSION=x.y.z optional)
	@scripts/build-dmg.sh

.PHONY: release
release: ## Build the DMG and publish it as GitHub release vVERSION (VERSION=x.y.z required)
	@[ -n "$(VERSION)" ] || { echo "Usage: make release VERSION=x.y.z"; exit 1; }
	@[ -n "$$NOTARY_PROFILE" ] || { echo "Set NOTARY_PROFILE to a notarytool keychain profile so the DMG is notarized."; exit 1; }
	@VERSION=$(VERSION) scripts/build-dmg.sh
	gh release create "v$(VERSION)" build/release/Tidemark-$(VERSION).dmg build/release/Tidemark-$(VERSION).dmg.sha256 \
		--title "Tidemark $(VERSION)" --generate-notes

# Maintenance
.PHONY: clean
clean: ## Clean the Xcode build products and local build artifacts
	xcodebuild clean -project $(PROJECT) -scheme $(SCHEME)
	rm -rf "$(CURDIR)/.build" "$(KIT_PATH)/.build"

.PHONY: format
format: ## Format Swift sources in place
	swift format -r -p -i .

.PHONY: lint
lint: ## Check Swift formatting
	swift format lint -r -p .

.PHONY: build-server
build-server: ## Write buildServer.json for SourceKit-LSP editors
	xcode-build-server config -project $(PROJECT) -scheme $(SCHEME)

# Help
.PHONY: help
help: ## List the available targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_.-]+:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
