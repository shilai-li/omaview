#!/usr/bin/env bash

# Unit tests for Layout.js. No Qt, no compositor, no shell.
#
#   bash test/layout-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."
exec node test/layout-test.js
