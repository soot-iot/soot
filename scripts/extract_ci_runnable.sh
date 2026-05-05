#!/usr/bin/env bash
# extract_ci_runnable.sh — extract CI-runnable shell stages from a
# markdown file.
#
# Pulls every fenced ```sh / ```bash code block that sits inside a
# `<!-- CI-RUNNABLE -->` ... `<!-- /CI-RUNNABLE -->` marker pair, and
# writes one shell script per marker pair to OUT_DIR. Code outside the
# markers, or inside markers but in a non-shell language (e.g.
# ```elixir, ```sql), is ignored.
#
# Stage names come from a labelled marker:
#
#     <!-- CI-RUNNABLE: setup-pki -->
#     ```sh
#     mix ash_pki.init --out priv/pki
#     ```
#     <!-- /CI-RUNNABLE -->
#
# Unlabelled markers fall back to "stage". The output filename is
# `NN-<name>.sh` with a 1-indexed two-digit prefix preserving source
# order, so a shell glob (`scripts/extracted/*.sh`) iterates stages
# in the right order.
#
# The runner counterpart is `run_ci_runnable.sh`.
#
# Usage:
#   extract_ci_runnable.sh INPUT.md OUT_DIR
#
# OUT_DIR is created if missing, and any existing `*.sh` in it is
# removed first so a stale extraction never silently re-runs.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 INPUT.md OUT_DIR" >&2
  exit 2
fi

INPUT="$1"
OUT_DIR="$2"

if [[ ! -f "$INPUT" ]]; then
  echo "$0: input not found: $INPUT" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
find "$OUT_DIR" -maxdepth 1 -type f -name '*.sh' -delete 2>/dev/null || true

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

in_block=0
in_fence=0
stage_idx=0
stage_name=""
stage_buf=""

flush_stage() {
  if [[ -z "$stage_buf" ]]; then
    stage_name=""
    return
  fi
  stage_idx=$((stage_idx + 1))
  local padded
  printf -v padded '%02d' "$stage_idx"
  local fname
  if [[ -n "$stage_name" ]]; then
    fname="${padded}-${stage_name}.sh"
  else
    fname="${padded}-stage.sh"
  fi
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '%s' "$stage_buf"
  } > "$OUT_DIR/$fname"
  chmod +x "$OUT_DIR/$fname"
  stage_buf=""
  stage_name=""
}

open_re='^<!--[[:space:]]*CI-RUNNABLE([[:space:]]*:[[:space:]]*([A-Za-z0-9_-]+))?[[:space:]]*-->[[:space:]]*$'
close_re='^<!--[[:space:]]*/CI-RUNNABLE[[:space:]]*-->[[:space:]]*$'

while IFS='' read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ $open_re ]]; then
    in_block=1
    in_fence=0
    if [[ -n "${BASH_REMATCH[2]:-}" ]]; then
      stage_name="$(slugify "${BASH_REMATCH[2]}")"
    else
      stage_name=""
    fi
    continue
  fi

  if [[ "$line" =~ $close_re ]]; then
    in_block=0
    in_fence=0
    flush_stage
    continue
  fi

  if (( in_block )); then
    if [[ "$line" =~ ^\`\`\` ]]; then
      if (( in_fence )); then
        in_fence=0
      else
        lang="${line#'```'}"
        lang="${lang%% *}"
        case "$lang" in
          sh|bash) in_fence=1 ;;
          *)       in_fence=0 ;;
        esac
      fi
      continue
    fi
    if (( in_fence )); then
      stage_buf+="$line"$'\n'
    fi
  fi
done < "$INPUT"

flush_stage
