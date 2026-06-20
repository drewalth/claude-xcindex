# Developer task runner for claude-xcindex.
#
# This is the canonical entrypoint for working ON the project. CI
# (.github/workflows/build.yml) calls these same targets, so what runs
# locally matches what runs in CI.
#
# Scripts under scripts/ are dev-only and never ship with the plugin.
# Distributed scripts live in hooks/ and bin/ and are not invoked here.

.DEFAULT_GOAL := help

.PHONY: help build build-debug test test_ci lint format test-hooks cursor-lint

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

test-hooks: ## Run the bash hook + launcher regression tests
	bash tests/hooks/test-session-start.sh
	bash tests/hooks/test-post-edit.sh
	bash tests/hooks/test-pre-grep.sh
	bash tests/test-preflight.sh

cursor-lint: ## Validate Cursor packaging (manifests + mcp.json + referenced paths)
	@for f in mcp.json .cursor-plugin/plugin.json .cursor-plugin/marketplace.json; do \
		jq empty "$$f" >/dev/null && echo "  ok: $$f" || { echo "  invalid JSON: $$f"; exit 1; }; \
	done
	@test -d skills        || { echo "  missing skills/ (plugin.json 'skills' override)"; exit 1; }
	@test -f assets/hero.png || { echo "  missing assets/hero.png (plugin.json 'logo')"; exit 1; }
	@test -x bin/run       || { echo "  missing executable bin/run (mcp.json 'command')"; exit 1; }
	@echo "cursor packaging OK"
