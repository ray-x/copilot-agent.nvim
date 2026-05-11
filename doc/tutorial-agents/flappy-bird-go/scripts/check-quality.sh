#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

cd "$project_root"

echo "Running go vet..."
go vet ./...

echo "Running go test..."
go test ./...

echo "Quality checks passed."
