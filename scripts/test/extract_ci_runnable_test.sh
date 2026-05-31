#!/usr/bin/env bash
# extract_ci_runnable_test.sh — exercises extract_ci_runnable.sh and
# run_ci_runnable.sh against `sample_runnable.md`. Run by hand:
#
#     scripts/test/extract_ci_runnable_test.sh
#
# Exits 0 on full pass; non-zero with a FAIL line on the first
# assertion that doesn't hold.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EXTRACT="$REPO_ROOT/scripts/extract_ci_runnable.sh"
RUN="$REPO_ROOT/scripts/run_ci_runnable.sh"
SAMPLE="$REPO_ROOT/scripts/test/sample_runnable.md"

TMP="$(mktemp -d -t ci-runnable-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ---- 1. Extraction shape -------------------------------------------------

OUT="$TMP/extracted"
"$EXTRACT" "$SAMPLE" "$OUT"

mapfile -t stages < <(cd "$OUT" && ls *.sh)

(( ${#stages[@]} == 3 )) \
  || fail "expected 3 stages, got ${#stages[@]}: ${stages[*]}"

[[ "${stages[0]}" == "01-workspace.sh"        ]] || fail "stage 0 = ${stages[0]}"
[[ "${stages[1]}" == "02-verify-greeting.sh"  ]] || fail "stage 1 = ${stages[1]}"
[[ "${stages[2]}" == "03-stage.sh"            ]] || fail "stage 2 = ${stages[2]} (unlabelled fallback)"

# ---- 2. Boundary correctness --------------------------------------------

# Decorative shell block (outside any marker) must NOT have leaked in.
if grep -q "/no/such/path" "$OUT"/*.sh; then
  fail "extracted code from outside CI-RUNNABLE markers"
fi

# Non-shell fenced blocks inside markers must NOT have leaked in.
if grep -q "config :my_app" "$OUT"/*.sh; then
  fail "extracted code from a non-shell fenced block"
fi

# Stage 2 must contain BOTH blocks (sh + bash) in source order.
grep -q 'test -d "$WORK_DIR/sub"'                "$OUT/02-verify-greeting.sh" \
  || fail "missing first sh block in stage 2"
grep -q 'grep -q "\^hello\$" "$WORK_DIR/greeting.txt"' "$OUT/02-verify-greeting.sh" \
  || fail "missing bash block in stage 2"

# Each stage starts with the canonical shebang + strict mode.
for s in "$OUT"/*.sh; do
  head -2 "$s" | diff -q - <(printf '#!/usr/bin/env bash\nset -euo pipefail\n') >/dev/null \
    || fail "stage $(basename "$s") missing canonical header"
done

# ---- 3. Happy-path execution --------------------------------------------

WORK_DIR="$TMP/work" "$RUN" "$SAMPLE" "$TMP/run-extract" >"$TMP/run.log" 2>&1 \
  || { cat "$TMP/run.log" >&2; fail "happy-path run exited non-zero"; }

[[ -f "$TMP/work/greeting.txt"      ]] || fail "stage 1 didn't create greeting.txt"
[[ -d "$TMP/work/sub"               ]] || fail "stage 1 didn't create sub/"
[[ -f "$TMP/work/third.txt"         ]] || fail "stage 3 didn't create third.txt"
[[ "$(cat "$TMP/work/third.txt")" == "third" ]] || fail "third.txt has wrong content"

# ---- 4. Failing-stage propagation ---------------------------------------

FAILDOC="$TMP/fail.md"
cat > "$FAILDOC" <<'EOF'
# Fail fixture

<!-- CI-RUNNABLE: passes -->
```sh
echo "ok" > /dev/null
```
<!-- /CI-RUNNABLE -->

<!-- CI-RUNNABLE: fails -->
```sh
exit 17
```
<!-- /CI-RUNNABLE -->

<!-- CI-RUNNABLE: never-runs -->
```sh
echo "should-not-execute" > "$WORK_DIR/never"
```
<!-- /CI-RUNNABLE -->
EOF

set +e
WORK_DIR="$TMP/fail-work" "$RUN" "$FAILDOC" "$TMP/fail-extract" >"$TMP/fail.log" 2>&1
rc=$?
set -e
mkdir -p "$TMP/fail-work"

(( rc != 0 )) || { cat "$TMP/fail.log" >&2; fail "runner returned 0 on a failing stage"; }
[[ ! -f "$TMP/fail-work/never" ]] \
  || fail "runner kept going after a failed stage"

# ---- 5. No-markers refusal ----------------------------------------------

NOOPDOC="$TMP/noop.md"
echo "no markers here" > "$NOOPDOC"

set +e
"$RUN" "$NOOPDOC" "$TMP/noop-extract" >"$TMP/noop.log" 2>&1
rc=$?
set -e

(( rc != 0 )) || fail "runner returned 0 on a doc with no CI-RUNNABLE markers"
grep -q "no CI-RUNNABLE stages" "$TMP/noop.log" \
  || fail "runner didn't print the expected diagnostic"

# ---- 6. Stale extractions are cleared -----------------------------------

STALE="$TMP/stale"
mkdir -p "$STALE"
touch "$STALE/99-stale.sh"
"$EXTRACT" "$SAMPLE" "$STALE" >/dev/null
[[ ! -f "$STALE/99-stale.sh" ]] \
  || fail "extractor didn't remove stale stage scripts"

echo "PASS: 6/6 assertion groups held"
