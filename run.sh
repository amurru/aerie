#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(realpath "$0")")"
if ! command -v godot >/dev/null 2>&1; then
  echo "Godot 4 is required. On Arch Linux: sudo pacman -S godot" >&2
  exit 1
fi
exec godot --path "$PWD" "$@"
