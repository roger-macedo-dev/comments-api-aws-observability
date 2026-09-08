#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
sed 's|](docs/|](|g' README.md > docs/index.md
echo "docs/index.md gerado a partir do README.md"
