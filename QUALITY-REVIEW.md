# `soot` (umbrella/meta) — Phase 6 quality review

Reviewed against `sprawl/soot/QUALITY-REVIEW.md` at commit `6dbd9b4`.
Findings ordered by severity within each group.

## Gate status (before review)

```
mix deps.unlock --check-unused   ✓ (after `mix deps.get`)
mix deps.audit                   ✗ task not found (mix_audit not installed)
mix format --check-formatted     ✗ test/support/fixtures.ex and
                                   test/soot/mix_tasks_test.exs dirty
                                   (the fixtures dirt is downstream of the
                                    missing `import_deps:` in .formatter.exs)
mix compile --warnings-as-errors ✓ for `:soot`; ash_mqtt dep emits
                                   `:emqtt` undefined warnings (out of scope)
mix credo --strict               ✗ task not found
mix sobelow                      ✗ task not found
mix test                         ✓ 11 tests, 0 failures
mix dialyzer                     ✗ task not found
```

## Correctness bugs

### 1. Generated project's `mix deps.get` fails immediately
`priv/templates/project/mix.exs.eex` lists every `soot_*` and `ash_*`
library with a hex version requirement (`{:ash_pki, "~> 0.1"}`, etc.).
None of these packages have been published to hex (the parent `soot`'s
own `mix.exs` lists them as `path: "../<name>"` deps). Running
`mix soot.new my_iot && cd my_iot && mix deps.get` yields:

```
** (Mix) No package with name ash_pki (from: mix.exs) in registry
```

I verified this end-to-end (`mix soot.new test_app --into /tmp/test_soot_gen`
then `mix deps.get` in that directory). The generator's primary purpose
— "scaffold a working starter project" — therefore does not actually
produce a working starter project today. Either:

* publish the libraries to hex first (and bump the requirement to a
  version that actually exists), or
* emit `path:` / `git:` deps in the template until publishing happens, or
* ship the generator's README-step-1 explaining how to point the
  generated `mix.exs` at local checkouts.

The generator silently producing broken output is the worst failure
mode here — operators will hit it on first contact.

References: `priv/templates/project/mix.exs.eex:25-44`,
`lib/mix/tasks/soot.new.ex:75-78` (the next-step hint walks the user
straight at `mix deps.get`).

### 2. `Soot.libraries/0` lists `ash_jwt` but `mix.exs` does not depend on it
`lib/soot.ex:25` includes `ash_jwt: %{module: AshJwt, role: …,
standalone?: true}` and the moduledoc enumerates it as a constituent
library. README's "Repos" table also marks it `**landed**`. But
`mix.exs` deps lists everything *except* `ash_jwt`, and `test/soot_test.exs`
tacitly acknowledges this with the comment "ash_jwt is intentionally NOT
a dep of `:soot` in v0.1 because it's an escape hatch."

The result is `Soot.extensions_loaded?/0` will always return `false`
even on a healthy install (because `Code.ensure_loaded?(AshJwt)` fails),
and the diagnostic claim in `Soot.libraries/0`'s docstring ("useful for
diagnostics and documentation generation") is misleading — the helper
reports a perpetually-broken state.

Pick one of:
1. Drop `ash_jwt` from `@libraries` (it's an escape hatch, not part of
   the meta package).
2. Add `{:ash_jwt, path: "../ash_jwt"}` (or `optional: true`) to
   `mix.exs` and accept the dependency.
3. Add an `optional?: true` flag to the library map and have
   `extensions_loaded?/0` ignore optional entries.

References: `lib/soot.ex:22-41`, `mix.exs:39-50`, `README.md:22`,
`test/soot_test.exs:21-26`.

### 3. `Soot.libraries/0` `ash_jwt` entry omits `:standalone?` test
`extensions_loaded?/0` checks whether each module is loaded. Combined
with bug 2, this means even after a clean compile of every library in
the framework, the test passes only because it asserts
`is_boolean(...)`, not `== true`. The test cannot detect any future
regression where one of the *real* deps (`AshPki`, `AshMqtt`, etc.)
isn't compiled into the build. A meaningful test is something like
`assert Soot.extensions_loaded?()` once `:ash_jwt` is removed from
`@libraries` (or wired into deps). See bug 2.

Reference: `test/soot_test.exs:21-26`.

### 4. `Mix.Tasks.Soot.New.run/1` crashes on options-only invocations
`run(["--module", "Foo"])` — i.e. the user remembers to pass `--module`
but forgets the app name — parses to `{[module: "Foo"], []}` and the
binding `[app_name | _] = []` raises `MatchError`. Only `run([])` is
guarded with the friendly `Mix.raise/1` "Usage: ..." message.

Either pattern-match the empty positional list after `OptionParser.parse!/2`
and call the same `Mix.raise/1`, or treat any positional miss as
"missing app name" before binding.

Reference: `lib/mix/tasks/soot.new.ex:38-41`.

### 5. `soot.broker.gen_config` short-circuits on missing template silently
`render_mosquitto_conf/4` checks `File.exists?(template_path)` and on
miss returns `:skipped` with no operator-visible output. The task as
shipped *does* include `priv/templates/mosquitto.conf.eex`, so this
branch never fires in normal use — but if an operator passes
`--mosquitto-template path/to/missing.eex` they get no warning that
their explicit template was ignored, and `mosquitto.conf` simply isn't
emitted while `mosquitto.acl` is. The shape of the bug is "passing a
typo'd path silently produces a partial output set."

Either `Mix.raise/1` when an explicitly-passed template doesn't exist
(reserve the `:skipped` branch for the can't-find-builtin case, which
should also probably raise rather than silently skip), or at minimum
`Mix.shell().info("    skip mosquitto.conf (template #{template_path} not found)")`.

Reference: `lib/mix/tasks/soot.broker.gen_config.ex:91-114`.

### 6. `Mix.Tasks.Soot.Broker.GenConfig.load_module/1` UX
`Code.ensure_loaded!/1` raises `ArgumentError: could not load module X
due to reason :nofile`. For a mix-task user who typo'd a module name,
the trailing OptionParser/load_module stack trace is noisy and the
message doesn't say "did you misspell `--resource`?". Mirror the
soot_telemetry / soot_contracts review finding: catch `:nofile` and
`Mix.raise/1` with "could not load resource module `X` — make sure
it's compiled and reachable from this project (did you forget
`MIX_ENV=test`?)".

Reference: `lib/mix/tasks/soot.broker.gen_config.ex:122-126`.

## Generator / task hygiene

### 7. Generated `mix.exs.eex` has the redundant `:crypto` / `:public_key` extras
`extra_applications: [:logger, :crypto, :public_key, :ssl]`. The
playbook's common-findings list has this exact one: `:ssl` already
pulls `:crypto` and `:public_key`. Fresh projects shouldn't be
shipped with the redundancy in their template.

Reference: `priv/templates/project/mix.exs.eex:17`.

### 8. Generated `mix.exs.eex` doesn't pin Elixir / OTP via `.tool-versions`
The generator emits `mix.exs` and source files but no `.tool-versions`.
The rest of the framework pins `1.18.3-otp-27` / `27.3`. Generated
projects should match the framework's pin so a fresh `mix soot.new`
dir is CI-ready out of the box.

Add a `priv/templates/project/.tool-versions` and copy it through the
same `Enum.each` pipeline.

Reference: `lib/mix/tasks/soot.new.ex:51-56`.

### 9. Generated project never gets a `lib/<app>.ex` despite the doc claim
The `Mix.Tasks.Soot.New` moduledoc:

> Produces a directory `my_iot/` with:
>
>   * `mix.exs` listing every Soot library as a hex dep
>   * `lib/my_iot.ex` and `lib/my_iot/application.ex`
>   * `lib/my_iot/endpoint.ex` …

But the task only writes `mix.exs`, `lib/<app>/application.ex`,
`lib/<app>/endpoint.ex`, and `README.md` — there is **no** `lib/<app>.ex`
template (and the `priv/templates/project/` dir doesn't contain one).
Either drop the claim or add the template (a one-line `defmodule
<%= module %> do @moduledoc "…"; end` would do).

Confirmed by inspection of `/tmp/test_soot_gen/lib/`:

```
test_app/
├── application.ex
└── endpoint.ex
```

References: `lib/mix/tasks/soot.new.ex:11-16`, `priv/templates/project/`.

### 10. Generated `application.ex` has every child commented out
The template's `children = [...]` body is entirely comments. The
README's "step 6: Start the app" instruction (`mix run --no-halt`)
silently launches an empty supervisor. There's no Bandit endpoint
listening, no repo started. A fresh user following the README step-by-
step won't notice their app is doing nothing until they `curl` the
endpoint and get a connection refused.

Either:
* Supervise an actual Bandit + the endpoint by default and document
  how to remove it, or
* Prefix the comment block with `# UNCOMMENT after running ash_pki.init`
  so the README and the template stay in sync, or
* Have the README step explicitly say "edit `lib/<app>/application.ex`
  to uncomment the supervised children".

The current shape is the least helpful of the three.

References: `priv/templates/project/application.ex.eex:6-17`,
`priv/templates/project/README.md.eex:51-55`.

### 11. `soot.broker.gen_config` `cond do … true -> :skip end` is awkward
```elixir
cond do
  only in [:both, :mosquitto] -> render_mosquitto(resources, out, opts)
  true -> :skip
end
```

Twice in a row. This is a credo `Refactor.CondStatements` antipattern
and reads strangely. Replace with `if` or `case`:

```elixir
if only in [:both, :mosquitto], do: render_mosquitto(resources, out, opts)
if only in [:both, :emqx],      do: render_emqx(resources, out)
```

Reference: `lib/mix/tasks/soot.broker.gen_config.ex:60-68`.

### 12. `OptionParser` switch tuple shape `[:string, :keep]`
```elixir
@switches [
  ...
  resource: [:string, :keep],
  ...
]
```

`OptionParser` accepts `[:string, :keep]` (list, not tuple) in modern
Elixir, but the more idiomatic / documented shape is the tuple
`{:string, :keep}` or a separate `keep:` list. Worth normalising for
consistency with the rest of the code base; this is also what the
ash_mqtt task generators use.

Reference: `lib/mix/tasks/soot.broker.gen_config.ex:32-42`.

### 13. `Mix.Task.run("app.start")` in the broker task is heavier than needed
`mix soot.broker.gen_config` runs `app.start` to load operator modules.
But the generator-style task pattern (cf. `mix ash_mqtt.gen.mosquitto_acl`)
typically runs `loadpaths` only — much faster, and avoids starting the
operator's full supervision tree (which can have side effects:
opening DB connections, starting Bandit on the server cert path even
when you're trying to *generate* the cert path). Consider:

```elixir
Mix.Task.run("loadpaths")
Mix.Task.run("compile")
```

instead of `app.start`, mirroring the existing `ash_mqtt.gen.*` tasks.

Reference: `lib/mix/tasks/soot.broker.gen_config.ex:46`.

## Doc-vs-code drift

### 14. README's deployment runbook step 3 doesn't mention the wrapper task
The whole point of `mix soot.broker.gen_config` (per the meta package's
own moduledoc and the SPEC §5.8) is to be the one-stop wrapper that
calls both ash_mqtt generators. But README §3 ("Broker configuration")
walks the user through `mix ash_mqtt.gen.mosquitto_acl` and
`mix ash_mqtt.gen.emqx_config` directly, without ever mentioning the
wrapper this very package ships. Either mention `mix soot.broker.gen_config`
as the recommended entry point, or remove it from `lib/mix/tasks/`.

References: `README.md:78-93`, `lib/mix/tasks/soot.broker.gen_config.ex:1-30`.

### 15. README's repo table lists `ash_jwt` as **landed**
Same root cause as bug 2. README claims `ash_jwt` shipped in Phase 6
and is part of the meta package. The meta package does not actually
pull it in. Either reflect the optionality in the table ("standalone /
opt-in escape hatch") or wire the dep.

Reference: `README.md:22`.

### 16. Generated `README.md.eex` step 5 references a stream that doesn't exist
Step 5 of the generated README:

```
mix soot_telemetry.gen_migrations \
    --out priv/migrations/V0001__telemetry.sql \
    --stream <%= module %>.Telemetry.MyStream
```

`<%= module %>.Telemetry.MyStream` is a placeholder that won't exist in
the freshly-scaffolded project (no `lib/<app>/telemetry/` is generated;
see bug 9). The user runs the command and gets `could not load module`.
Either:
* drop step 5 entirely from the generated README (defer it to "after
  you define your first stream"), or
* generate a stub `lib/<app>/telemetry/my_stream.ex` template the user
  can edit, or
* prefix the snippet with "After you've defined a `Telemetry.Stream`,
  e.g. …".

Same shape applies to step 6 (`<%= module %>.Telemetry.MyStream`,
`<%= module %>.Devices.Device`).

References: `priv/templates/project/README.md.eex:34-49`.

### 17. SPEC.md mix-task names use the old dotted form
SPEC.md §5.4–§5.6 references `mix soot.telemetry.gen_migrations`,
`mix soot.telemetry.migrate`, `mix soot.segments.gen_migrations`,
`mix soot.segments.migrate`. The actual tasks are
`mix soot_telemetry.gen_migrations` and `mix soot_segments.gen_migrations`
(underscore), and `migrate` was never built ("framework intentionally
does not ship a ClickHouse migration runner" per `README.md:112-115`).
SPEC is authored in dotted form; code shipped underscored. Update the
spec or rename the tasks.

References: `SPEC.md:269,270,293,294`,
`lib/mix/tasks/soot_telemetry.gen_migrations.ex` (in soot_telemetry).

### 18. SPEC.md §5.8 lists `mix soot.demo` — it doesn't exist
`SPEC.md:362-365`:
> Mix tasks:
>   * `mix soot.new` — generate a fresh project …
>   * `mix soot.broker.gen_config` — render EMQX or Mosquitto config …
>   * `mix soot.demo` — spin up a demo with a couple of simulated devices …

`lib/mix/tasks/` only has `soot.new.ex` and `soot.broker.gen_config.ex`.
Either drop the spec line or note it as deferred.

Reference: `SPEC.md:364-365`.

## Test gaps

### 19. No test asserts the generated project's `mix.exs` actually compiles
The closest the test suite gets is grepping for `defmodule MyIot.MixProject`
in the rendered file. Given bug 1 (generated `mix.exs` is broken), a
test that does `Mix.shell(Mix.Shell.Quiet); Mix.Tasks.Soot.New.run([…]);
{out, 0} = System.cmd("mix", ["compile"], cd: target, env: [...])` would
have caught the missing-package issue. Even a lightweight
"`Code.string_to_quoted!` the rendered template and confirm it has the
expected children" parse-only assertion would catch a future template
typo.

Reference: `test/soot/mix_tasks_test.exs:20-69`.

### 20. No test for the `--module` override producing a valid Elixir module name
`test/soot/mix_tasks_test.exs:35-49` asserts the generated `mix.exs`
contains `defmodule Acme.IoT.MixProject`. But what if a user passes
`--module my_iot` (lower-case)? Or `--module 1Foo` (digit-leading)?
The task does no validation; an invalid module name produces a file
that doesn't parse and `mix compile` will fail downstream with a
confusing error. Either validate the `--module` value (must match
`~r/\A[A-Z][A-Za-z0-9_.]*\z/`) and `Mix.raise/1` on miss, or test
that the existing behaviour is intentional.

Reference: `lib/mix/tasks/soot.new.ex:43`.

### 21. Broker task has no test for `--mosquitto-template path/that/doesnt/exist`
Tied to bug 5. There is no test for the silent-skip branch. Add one
and pin the desired behaviour (raise vs. info-line vs. fall-back to
the bundled template).

Reference: `test/soot/mix_tasks_test.exs:72-149`.

### 22. Broker task has no test for `--ca-file/--cert-file/--key-file`
The mosquitto.conf template substitutes these bindings. The current
test doesn't assert the rendered `mosquitto.conf` actually contains
the operator-supplied paths, only that the file *exists*. Add an
assertion that passes `--ca-file /tmp/x` and confirms `cafile /tmp/x`
appears in the rendered config.

Reference: `test/soot/mix_tasks_test.exs:73-91`,
`priv/templates/mosquitto.conf.eex:10-12`.

### 23. `Soot.extensions_loaded?/0` test only checks return-type
```elixir
assert is_boolean(Soot.extensions_loaded?())
```

This passes whether the function returns `true`, `false`, or… well,
not a boolean; the test would fail in that case. But it doesn't tell
you anything about the actual loaded state. See bug 3.

Reference: `test/soot_test.exs:21-26`.

### 24. `test_helper.exs` doesn't enable `capture_log: true`
A bare `ExUnit.start()`. Same finding as soot_telemetry / soot_contracts;
add `capture_log: true` as the floor.

Reference: `test/test_helper.exs:1`.

## Tooling gaps

### 25. No `LICENSE` file
`mix.exs` declares `licenses: ["MIT"]` but no `LICENSE` ships in the
repo. Same finding as soot_contracts. Mirror the soot_telemetry MIT
text.

### 26. Hex package metadata incomplete
* `links: %{}` — empty map. Hex requires a non-empty map in practice;
  add at least `"GitHub" => @source_url`.
* No `@source_url`, no `source_url:` in `project/0`.
* No `docs:` config.
* No `aliases:` (soot_telemetry has `format: "format --migrate"` and
  `credo: "credo --strict"`).
* `package: files:` is `~w(lib priv .formatter.exs mix.exs README.md
  SPEC.md SCALING.md)` — missing `LICENSE*` and `CHANGELOG*`.

Reference: `mix.exs:31-37`.

### 27. `consolidate_protocols: Mix.env() != :test`
Should be `Mix.env() == :prod`. Same playbook finding as soot_core /
soot_telemetry / soot_contracts.

Reference: `mix.exs:13`.

### 28. No `.tool-versions`
Pin `elixir 1.18.3-otp-27` / `erlang 27.3` to keep CI and local in
sync — same pin used in the rest of the stack. Soot is the meta
package; if anything in the stack should pin its toolchain, it's
this one.

### 29. No `CHANGELOG.md`
Mirror `soot_telemetry/CHANGELOG.md`. First entry: "Initial Phase 6
release: `mix soot.new` generator, `mix soot.broker.gen_config`
wrapper, deployment runbook, scaling-cliff doc."

### 30. No CI workflow
Mirror `soot_telemetry/.github/workflows/elixir.yml` — same gate steps.

### 31. No lint stack
No `.credo.exs`, no `.dialyzer_ignore.exs`, no `.sobelow-conf`. No
deps for `:credo`, `:dialyxir`, `:sobelow`, `:mix_audit`, `:ex_doc`.

### 32. `.formatter.exs` is missing `import_deps:` for `:ash`, `:spark`, `:ash_mqtt`
`test/support/fixtures.ex` defines an `Ash.Domain`, an `Ash.Resource`,
and uses the `mqtt do … end` DSL. Without `import_deps: [:ash, :spark]`
in `.formatter.exs`, the formatter doesn't know that `resource`,
`uuid_primary_key`, `defaults`, `topic`, etc. are macros that take
unbracketed args, so `mix format --check-formatted` fails on idiomatic
DSL code. Same fix as in `soot_telemetry/.formatter.exs`:

```elixir
[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

(or `[:ash, :spark, :ash_mqtt]` if ash_mqtt also exposes a formatter).

Reference: `.formatter.exs:1-3`.

### 33. `erl_crash.dump` checked into the working tree
The repo root contains an 8.0 MB `erl_crash.dump`. `.gitignore` already
lists `erl_crash.dump` so it's an "untracked" leftover from a previous
run, but worth deleting to keep the workspace clean (and verifying
.gitignore is respected). I have not removed it because the playbook
constraint is "don't modify any source," but it should go.

Reference: `erl_crash.dump`, `.gitignore:6`.

## Stylistic / minor

### 34. Formatter dirty (downstream of finding 32)
`mix format --check-formatted` reports two files dirty:
* `test/soot/mix_tasks_test.exs` — the line at `:90` is over the
  98-char limit (the `assert {:ok, %{"acl" => _, "rules" => _}} = …`
  line).
* `test/support/fixtures.ex` — every DSL macro (`resource`,
  `uuid_primary_key`, `defaults`, `topic`) gets parens added because
  the formatter doesn't know about the DSL's `:locals_without_parens`.

Fixing finding 32 alone resolves the fixtures dirt; the
mix_tasks_test.exs line wraps independently.

References: `test/soot/mix_tasks_test.exs:90`, `test/support/fixtures.ex`.

### 35. `Soot` moduledoc lists every constituent library by hand
```elixir
@moduledoc """
…the constituent libraries (`ash_pki`, `ash_mqtt`, `soot_core`,
`soot_telemetry`, `soot_segments`, `soot_contracts`, `soot_admin`).
…
"""
```

The same list is then defined as `@libraries` immediately below.
Either generate the moduledoc fragment from `@libraries` (via
`@moduledoc` + module-attribute interpolation, or `@before_compile`),
or add a comment "keep this list in sync with `@libraries`." Today
the moduledoc and the map disagree on `ash_jwt` (see bug 2).

Reference: `lib/soot.ex:2-31`.

### 36. SCALING.md uses the unqualified `Plug.Ingest` shorthand twice
`SCALING.md:41,62` says `Plug.Ingest` rather than `SootTelemetry.Plug.Ingest`.
Readers grepping the codebase for `Plug.Ingest` find nothing. Minor;
either spell out the full module name or note the shorthand once at
the top.

References: `SCALING.md:41,62`.

### 37. README.md's "Quickstart" section bottoms out in `cd ash_pki`
`README.md:212-220` walks the user through working on the `ash_pki`
library directly rather than using the `soot` umbrella. That's fine
as a "single-library, dev-only" path, but the heading suggests this
*is* the soot quickstart — there's no equivalent "use mix soot.new"
quickstart anywhere in the README. Add one (`mix soot.new my_iot`,
the four next steps) so the meta-package README has an obvious
"start here" path that uses the meta package.

Reference: `README.md:212-220`.

### 38. `Soot.extensions_loaded?/0` `@spec` doesn't reflect the constraint
The function returns `true` only when *all* `@libraries` modules load,
`false` otherwise. The spec says `boolean()` which is correct but
uninformative. Consider documenting which libraries are checked — or,
better, rename to `loaded?/0` and add a `loaded/0` returning the list
of loaded modules so the diagnostics use case becomes actionable
("which one is missing?") rather than binary.

Reference: `lib/soot.ex:38-41`.
