#!/usr/bin/env bash
# broadcast_assembler.sh — launches the latest versioned assembler
# Frozen copies: broadcast_assembler_v1.sh, broadcast_assembler_v2.sh, ...
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
latest="$(ls -1 "$DIR"/broadcast_assembler_v[0-9]*.sh 2>/dev/null | sort -V | tail -n 1 || true)"
if [[ -z "$latest" ]]; then
  echo "No versioned assembler found next to $0" >&2
  exit 1
fi
echo "Launching $(basename "$latest")"
exec bash "$latest" "$@"
