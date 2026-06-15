# Developer task runner for claude-xcindex.
#
# This is the canonical entrypoint for working ON the project. CI
# (.github/workflows/build.yml) calls these same targets, so what runs
# locally matches what runs in CI.
#
# Scripts under scripts/ are dev-only and never ship with the plugin.
# Distributed scripts live in hooks/ and bin/ and are not invoked here.

.DEFAULT_GOAL := help

.PHONY: help build build-debug test test_ci lint format test-hooks

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Release build of the xcindex binary
	./scripts/build.sh

build-debug: ## Debug build of the xcindex binary
	./scripts/build.sh --debug

test: ## Run the Swift test suite
	cd service && swift test --parallel

test_ci: ## Run the Swift test suite as CI does (skips external fixtures)
	cd service && XCINDEX_ALLOW_FIXTURE_SKIP=1 swift test --parallel

lint: ## Check formatting with SwiftFormat (no changes)
	swiftlint . --config .swiftlint.yml && swiftformat --lint .

format: ## Auto-format the codebase with SwiftFormat
	swiftlint . --config .swiftlint.yml --fix && swiftformat .

test-hooks: ## Run the bash hook regression tests
	bash tests/hooks/test-session-start.sh
