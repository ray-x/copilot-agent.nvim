#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bootstrap.sh <target-directory>

Example:
  bootstrap.sh ~/flappy-bird-go
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="$1"

copy_tree() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  cp -R "$src"/. "$dst"/
}

mkdir -p "$target_dir"
copy_tree "$source_dir/.github" "$target_dir/.github"
copy_tree "$source_dir/prompts" "$target_dir/prompts"
copy_tree "$source_dir/scripts" "$target_dir/scripts"

if compgen -G "$target_dir/scripts/*.sh" >/dev/null; then
  chmod +x "$target_dir"/scripts/*.sh
fi

cat <<EOF
Bootstrapped Flappy Bird tutorial project assets into:
  $target_dir

Copied:
  - .github/copilot-instructions.md
  - .github/agents/
  - .github/skills/
  - prompts/
  - scripts/
EOF
