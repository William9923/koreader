#!/usr/bin/env bash

set -euo pipefail

# Run FolderLock headless tests only.
# Use busted runner for reliable name filtering in local workflows.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${ROOT_DIR}"

./kodev test --busted all -f "FolderLock plugin" -x
