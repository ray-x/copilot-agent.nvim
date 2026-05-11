#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"

cd "$project_root"

if [[ ! -f go.mod ]]; then
  echo "go.mod not found in $project_root"
  echo "Generate the project first, then run this script again."
  exit 1
fi

exec go run .
