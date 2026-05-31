# Sample CI-Runnable Documentation

Test fixture for `scripts/extract_ci_runnable.sh` + `scripts/run_ci_runnable.sh`.
Exercises the full marker grammar so the test can pin behaviour
without depending on the project README. The runner is invoked with
`WORK_DIR` set to a tmp directory; every shell stage assumes that.

## A labelled stage with one block

The first stage just creates a workspace.

<!-- CI-RUNNABLE: workspace -->

```sh
mkdir -p "$WORK_DIR/sub"
echo "hello" > "$WORK_DIR/greeting.txt"
```

<!-- /CI-RUNNABLE -->

This `elixir` snippet is for the reader, not for CI:

```elixir
config :my_app, :greeting, "hello"
```

## A labelled stage with two shell blocks

Both blocks below should land in the same extracted stage script,
in source order, joined into one shell program. The second block
is tagged `bash` rather than `sh` — both must be picked up.

<!-- CI-RUNNABLE: verify-greeting -->

```sh
test -d "$WORK_DIR/sub"
```

```bash
grep -q "^hello$" "$WORK_DIR/greeting.txt"
```

<!-- /CI-RUNNABLE -->

## An unlabelled stage

Marker without a `: name` suffix — the extractor falls back to a
generic stage filename so the run still proceeds.

<!-- CI-RUNNABLE -->

```sh
echo "third" > "$WORK_DIR/third.txt"
```

<!-- /CI-RUNNABLE -->

## Decorative blocks the extractor must skip

Outside any marker pair. The runner would fail loudly if this
shell block were extracted, so it doubles as a negative assertion:

```sh
cat /no/such/path
echo "this should never run"
```

A SQL example, also outside markers, also must be ignored:

```sql
SELECT * FROM nowhere;
```
