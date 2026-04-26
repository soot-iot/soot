# Changelog

All notable changes to `soot` (the meta / umbrella package) are
documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project adheres to semantic versioning.

## [Unreleased]

### Added
- `lib/<app>.ex` template emitted by `mix soot.new` (the moduledoc
  already promised this; now it actually ships).
- `.tool-versions` template emitted by `mix soot.new`.
- `optional?: true` flag on `@libraries` entries; `extensions_loaded?/0`
  skips optional entries (today, just `ash_jwt`).
- `--module` value validation in `mix soot.new` (rejects names that
  aren't a valid Elixir module).
- Integration tests for the broker task's `--mosquitto-template`
  missing-file path, the `--ca-file`/`--cert-file`/`--key-file`
  template substitution, and a parse-check on the rendered
  `mix.exs` template.

### Changed
- `mix soot.new`'s generated `mix.exs` now uses `path: "../<dep>"`
  for every framework library (was hex requirements that don't
  exist on hex yet — `mix deps.get` failed immediately).
- `mix soot.broker.gen_config` raises a clear error if
  `--mosquitto-template` points at a non-existent file (was a
  silent partial-output skip).
- `mix soot.broker.gen_config`'s `load_module/1` raises a friendly
  message on `:nofile` instead of the bare `Code.ensure_loaded!/1`
  ArgumentError.
- `mix soot.broker.gen_config` runs `loadpaths` + `compile` instead
  of `app.start` (mirrors ash_mqtt's gen.* tasks; doesn't boot the
  operator's full supervision tree to render config).
- `mix soot.new` raises the friendly "Usage:" message on
  options-only invocations (was MatchError).
- `consolidate_protocols` is now `Mix.env() == :prod` (was
  `!= :test`).

### Fixed
- Generator README step 6 now mentions editing `application.ex`
  before `mix run --no-halt` (template's children list is
  intentionally commented out).

## [0.1.0] - 2026-04-26

### Added
- Initial Phase 6 release: `mix soot.new` project generator,
  `mix soot.broker.gen_config` Mosquitto+EMQX config wrapper,
  deployment runbook in `README.md`, scaling-cliff documentation
  in `SCALING.md`.
