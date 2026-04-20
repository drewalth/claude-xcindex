#!/usr/bin/env bash
# Thin compatibility alias kept so existing docs and muscle memory
# keep working. New fixtures should use `scripts/fetch-fixture.sh <name>`
# directly.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/fetch-fixture.sh" tca "$@"
