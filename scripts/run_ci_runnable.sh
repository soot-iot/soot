#!/usr/bin/env bash
# run_ci_runnable.sh — extract CI-RUNNABLE stages from a markdown file
# and execute them in source order.
#
# Aborts on the first stage that exits non-zero. The extracted scripts
# are kept on disk so a failing stage can be re-run by hand for
# debugging:
#
#     bash <OUT_DIR>/02-seed.sh
#
# Caller's responsibility: bring up any infra the stages depend on
# (Postgres, ClickHouse, MQTT broker, etc.) BEFORE invoking this. The
# stages themselves are whatever the markdown says they are.
#
# Usage:
#   run_ci_runnable.sh INPUT.md [OUT_DIR]
#
# OUT_DIR defaults to a fresh tmp dir.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 INPUT.md [OUT_DIR]" >&2
  exit 2
fi

INPUT="$1"
OUT_DIR="${2:-$(mktemp -d -t ci-runnable.XXXXXX)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/extract_ci_runnable.sh" "$INPUT" "$OUT_DIR"

shopt -s nullglob
stages=("$OUT_DIR"/*.sh)
shopt -u nullglob

if (( ${#stages[@]} == 0 )); then
  echo "[ci-runnable] no CI-RUNNABLE stages found in $INPUT" >&2
  exit 1
fi

for stage in "${stages[@]}"; do
  echo "[ci-runnable] running $(basename "$stage")"
  bash "$stage"
done

echo "[ci-runnable] all ${#stages[@]} stages passed (extracted to $OUT_DIR)"
