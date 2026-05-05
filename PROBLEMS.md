# Soot — production-blocking gaps

Live punch list of things that don't yet work end-to-end in a real
deployment. The bar: "would a real operator hit this on the path
through the README?"

The original v0.1 sweep found three blockers
(`SootTelemetry.Writer.Noop` default, ETS-only OLTP layer, software-
only contract bundle signing); all three landed in PRs through
2026-04-29 and are no longer tracked here. The current contents are
the gaps surfaced by the E2E reproducer plus context on what's
already deferred to SPEC-2 / verified working.

---

## Already covered or explicitly deferred (no action needed)

These are real gaps but already documented in `SPEC-2.md` or
explicitly marked as stubs in their module docs:

* `AshMqtt.Runtime.Client` no reconnect / backoff —
  `ash_mqtt/lib/ash_mqtt/runtime/client.ex:128-148`. SPEC-2 §3.1,
  Phase 7.
* `SootContracts.Plug.WellKnown` no rate limit. SPEC-2 §3.1, Phase 7.
* `AshPki.KeyStrategy.KMS` — every callback returns
  `{:error, :not_implemented}`
  (`ash_pki/lib/ash_pki/key_strategy/kms.ex:27-39`). Openly documented
  as a deferred stub in the moduledoc; not claimed as shipped.
* `SootCore.DeviceShadow` last-write-wins per top-level key. SPEC-2
  §5.5, Phase 8.
* `AshPki.Plug.MTLS` verified-header production hardening. SPEC-2 §5.6,
  Phase 7.

---

## Verified working (no action needed)

Spot-checked because they looked like candidates but are actually
real:

* `SootTelemetry.RateLimiter` — real ETS-backed token bucket with
  per-key refill math (`rate_limiter.ex:51-83`).
* `AshMqtt.Runtime.Client` publishes through a real `emqtt` transport
  (`runtime/client.ex:151-153`); only reconnect/backoff is missing.
* `SootContracts.Publisher.publish!/2` actually persists `BundleRow`s
  and supersedes the previous `:current` row
  (`publisher.ex:17-44`).
* `SootAdmin.SegmentChart` returning SQL + column metadata instead of
  rendering charts is documented design, not a stub
  (`charts/segment_chart.ex:1-25`).
* `SootSegments` DDL / SQL emission is real and exercised
  (`soot_segments/lib/soot_segments/clickhouse/{ddl,sql}.ex`).

---

## Carry-over tech debt

* **README Quickstart flags are wrong.** Two separate issues, both
  verified 2026-05-05 against the underlying generators' source.

  *`--with-args="--database postgres"` (backend Quickstart, line 38)
  is redundant.* `phx.new`'s `--database` already defaults to
  `postgres` (`phx_new/lib/mix/tasks/phx.new.ex:32` — "Defaults to
  \"postgres\""). Drop the flag; nothing changes about the generated
  project. The `ash_postgres.install` step composed by `soot.install`
  patches the existing `lib/<app>/repo.ex` that phx.new produced —
  the database adapter selection happens upstream of ash_postgres
  regardless.

  *`--with-args="--target qemu_aarch64"` (device Quickstart, line 84)
  is restrictive, not required.* `nerves.new` (verified at
  `nerves_bootstrap/lib/mix/tasks/nerves.new.ex:181-205`) treats
  `--target` as a *limit*: when omitted, the generated `mix.exs`
  lists **all** officially supported Nerves systems under
  `@all_targets` (`bbb`, `grisp2`, `osd32mp1`, `mangopi_mq_pro`,
  `qemu_aarch64`, `rpi`, `rpi0`, `rpi0_2`, `rpi2`, `rpi3`, `rpi4`,
  `rpi5`, `x86_64`). Passing `--target qemu_aarch64` cuts the list
  down to just `[:qemu_aarch64]` — confirmed by inspecting the
  scaffolded `my_device/mix.exs` here (`@all_targets [:qemu_aarch64]`,
  only the qemu system pulled in). The generic device Quickstart
  should drop the flag so consumers get support for every official
  Nerves system out of the box and select between them at build
  time via `MIX_TARGET`. The `--target qemu_aarch64` form belongs
  *only* in the "Try it locally (QEMU device + example backend)"
  section / `scripts/integration_e2e.sh`, where qemu is the explicit
  goal — and even there, dropping the flag still works because
  qemu_aarch64 is in the default set; the only reason to keep it
  there is to shrink dep-resolution and compile time for the
  reproducer.

  Both flags are documentation drift, not functional bugs — projects
  generated with them work, but the README mis-presents necessary
  vs. optional, and the device flag actively blocks "support all
  official Nerves systems."

* **README's `mix ash.setup` step does not run migrations on a
  fresh Postgres — resolved 2026-05-05.** `soot.install` now
  appends `"citext"` to the consumer Repo's `installed_extensions/0`
  callback as a defense-in-depth step (`ensure_citext_extension/1`
  in `lib/mix/tasks/soot.install.ex`). The next codegen run picks
  up the addition and emits a `CREATE EXTENSION IF NOT EXISTS
  "citext"` migration before any users-with-email migration, so
  `mix ash.setup` succeeds on a fresh `postgres:16` image without
  the operator running `psql … CREATE EXTENSION citext` out-of-band.

  Original finding for context:

  Following the backend Quickstart literally (line 42,
  `mix ash.setup`), migrations failed before any DDL was applied
  because the merged Initialize/AddAuthenticationResources
  migration created `users` with `citext` email columns before any
  `CREATE EXTENSION citext` had run. Dev machines with a
  long-lived postgres typically had citext pre-loaded, which is why
  this hid on local dev boxes; any fresh `postgres:16` image hit
  it. Net effect: the README's documented happy path did not
  produce a working schema on a clean install.

  Why `soot.install` rather than upstream: `ash_authentication.install`
  *does* call `AshPostgres.Igniter.add_postgres_extension(repo,
  "citext")` in its `setup_data_layer/2` step (verified in
  `ash_authentication 4.13.7` at
  `lib/mix/tasks/ash_authentication.install.ex:457-461`), but in
  practice that addition has been observed not to land in the
  on-disk Repo file when the task is composed via the soot install
  chain — the in-memory Igniter modification fails to persist.
  Reproduced 2026-05-05 via `mix igniter.new my_probe --with
  phx.new --install soot@path:…`: the generated `lib/my_probe/repo.ex`
  contained only `["ash-functions"]`. Composing
  `ash_authentication.install` against the same project in
  isolation correctly produced `["ash-functions", "citext"]`, so
  the function works; something in the soot chain interferes with
  it. Belt-and-braces in `soot.install` is idempotent
  (`add_postgres_extension/3` uses `append_new_to_list/2`) and
  guaranteed to land regardless of whether the upstream addition
  sticks; root-causing the upstream interference is a separate
  follow-up.

* **`soot_device.install` writes `:kernel` config to the wrong file,
  triggering Elixir's "Cannot configure base applications" warning
  on every `mix` invocation with `MIX_TARGET=qemu_aarch64`.**
  Reproduced 2026-05-05 against a freshly-scaffolded `my_device`:

  ```
  $ export MIX_TARGET=qemu_aarch64
  $ mix deps.get
  Cannot configure base applications: [:kernel]

  These applications are already started by the time the configuration
  executes and these configurations have no effect.
  …
  This happened when loading config/config.exs or
  one of its imports.

  Resolving Hex dependencies...
  Resolution completed in 0.145s
  ```

  Cause: `soot_device.gen.tests.ex:194-208` (`patch_target_dist_config/1`)
  inserts `config :kernel, inet_dist_listen_min: 9100,
  inet_dist_listen_max: 9100` into `config/target.exs:3`. Intent is
  to pin the Erlang distribution listen ports so the README's
  QEMU one-liner (`hostfwd=tcp::9100-:9100`) lines up. But `:kernel`
  is one of the OTP applications started *before* Mix loads project
  config, so any `config :kernel, …` in compile-time config files
  has no effect — Elixir 1.18+ surfaces this as the warning above.
  The warning is non-fatal (deps still resolve), but it fires on
  every `mix deps.get`, `mix compile`, `mix test`, `mix firmware`,
  etc. against the qemu target.

  The same project's `rel/vm.args.eex` already uses the correct
  pattern for kernel config (`-kernel shell_history enabled`,
  `+C multi_time_warp`, etc. as VM args). Fix path: drop the
  `patch_target_dist_config/1` step from `soot_device.gen.tests`
  and instead emit two lines into `rel/vm.args.eex`:

  ```
  -kernel inet_dist_listen_min 9100
  -kernel inet_dist_listen_max 9100
  ```

  Wrap them in the same `<%= if Mix.env() == :test do %>` block
  the existing `-name`/`-setcookie` lines use, since the port
  pinning only matters when QEMU is running the test build and
  forwarding 9100 to the host. Cross-repo follow-up: PR to
  `soot_device`.

* **`override: true` on github-branch deps is redundant** — landed
  2026-04-28 as part of the path-dep → github migration. While
  individual repo PRs were in flight, transitive deps still carried
  pre-merge `path:` declarations, so top-level mix.exs files needed
  `override: true` to win the dep-resolution conflict. Now that every
  repo's `main` declares its sibling deps as
  `{:dep, github: "soot-iot/dep", branch: "main"}`, the override is
  load-bearing nowhere — both sides of the resolution match by source
  type. Affects `soot_telemetry`, `soot_segments`, `soot_admin`,
  `soot_contracts`, `soot`. Removing the keyword is a no-op cleanup;
  leaving it is harmless. Worth a sweep when one of those mix.exs
  files is touched for an unrelated reason.

---

## E2E reproducer scope limits

`scripts/integration_e2e.sh` and `.github/workflows/integration.yml`
exercise the README's Quickstart literally. The reproducer
intentionally takes shortcuts that production deployments do not;
keep them on this list so we don't forget which gaps the green-CI
state is hiding.

* **E2E brokers run anonymous-allow on plain TCP.** Both
  `scripts/docker-compose.emqx.yml` (`EMQX_ALLOW_ANONYMOUS: "true"`)
  and `scripts/docker-compose.mosquitto.yml`
  (`allow_anonymous true`) skip ACLs, authentication, and TLS.
  Acceptable for this reproducer — the goal is "does the README's
  Quickstart wire bits end-to-end", not "does the production wire
  path with mTLS + ash_pki-issued device certs + EMQX ACL/authn
  rules survive". A second integration suite covering the
  `mix soot.broker.gen_config` → `mix soot.broker.push.emqx` path
  with mTLS-enforced listeners is a separate workstream and not
  blocked by this one.

* **`:soot` and `:soot_device` not on Hex.** The README's
  `mix igniter.new my_iot --install soot ...` form assumes hex
  resolution. Until the meta-packages are published, the E2E
  reproducer uses the github form
  (`--install soot@github:soot-iot/soot@<ref>`), parameterized via
  `SOOT_E2E_REF` / `SOOT_DEVICE_E2E_REF`. The README does not
  document this fallback. Update the README's Quickstart once Hex
  publishing is in place; until then, README-following evaluators
  will see "package soot not found" from hex.

* **`mix igniter.install <name>@github:...` does not run the
  install task.** Verified locally 2026-04-30: after step 2 the
  project has `:soot` in `mix.exs` and the soot deps fetched, but
  zero soot-generated files (no resources, no admin, no router
  pipelines). Running `mix soot.install --yes` as a separate third
  step generates the expected 50+ files and produces the install
  task's next-steps output. So the script does that explicitly.
  The README's "Why two steps?" section claims a single
  `mix igniter.install soot@github:...` is enough — that's wrong
  for this form. Either fix igniter to run the install task for
  github-source installs, or update the README to document the
  three-step reality.

* **PR self-test on `soot-iot/soot`.** `integration.yml` passes
  `${{ github.event.pull_request.head.sha || github.sha }}` as
  `SOOT_E2E_REF` so the test exercises the PR's own commit. This
  works for PRs from branches inside `soot-iot/soot` but does not
  cover PRs from forks where the head SHA isn't fetchable from the
  canonical repo. Fork PRs will fall back to whatever git resolves
  the ref to (typically nothing — the `--install` step then fails).
  Acceptable while the project is internal.

* **Generated consumer resources point at the library domain that
  doesn't accept them.** Surfaced 2026-05-04 in PR #13's E2E run.
  Each per-library installer (`ash_pki.install`, `soot_core.install`,
  `soot_segments.install`, `soot_contracts.install`) generates
  `lib/<app>/<resource>.ex` with a hard-coded
  `domain: <Lib>.Domain` line. The library-side domains list only
  the library's own internal resources, so the consumer module
  fails verification at module load with:

      ** (RuntimeError) Resource MyIot.SegmentVersion declared that
      its domain is SootSegments.Domain, but that domain does not
      accept this resource.

  Specifically:

  | library | install task | generated resources | library domain accepts? |
  |---------|--------------|---------------------|-------------------------|
  | `ash_pki`        | hard-codes `domain: AshPki.Domain`        | CertificateAuthority, Certificate, RevocationList, EnrollmentToken | no |
  | `soot_core`      | hard-codes `domain: SootCore.Domain`      | Tenant, SerialScheme, ProductionBatch, Device, DeviceShadow, EnrollmentToken | yes (`allow_unregistered? true`) |
  | `soot_segments`  | hard-codes `domain: SootSegments.Domain`  | SegmentRow, SegmentVersion | no |
  | `soot_contracts` | hard-codes `domain: SootContracts.Domain` | BundleRow | no |

  **Fix path (cross-repo).** Each library either (a) adds
  `allow_unregistered? true` to its `<Lib>.Domain` resources block
  (what soot_core already does), or (b) appends
  `validate_domain_inclusion?: false` to the generated consumer
  module body (what `soot.install`'s `--example` shadow generator
  does at `soot/lib/mix/tasks/soot.install.ex:331`). Option (a)
  is one line per library. Option (b) is consistent with the
  pattern the meta-package already uses. Either is fine; pick one
  per library and stick with it.

  **Impact.** Errors are emitted at runtime during DSL verification.
  The backend supervisor catches and the HTTP path stays up, but
  any code path that loads these resources crashes —
  `MyIot.Certificate`, `MyIot.SegmentRow`, `MyIot.BundleRow`, etc.
  are unusable. Real telemetry / contract / certificate operations
  through the umbrella will hit this. Cross-repo follow-up: PRs
  to ash_pki, soot_segments, soot_contracts.

* **ClickHouse credentials not threaded through `soot.install`.**
  `scripts/docker-compose.base.yml` brings ClickHouse up with
  `CLICKHOUSE_USER: soot / CLICKHOUSE_PASSWORD: soot`, but the
  generated project's `:ch` config uses driver defaults (user
  `default`, no password) and connect attempts fail every few
  seconds with `Code: 194 Authentication failed` for the lifetime
  of the backend process. soot.install configures `SOOT_BROKER_*`
  env vars at `soot/lib/mix/tasks/soot.install.ex:459-468` but
  has no equivalent for ClickHouse. Follow-up: add `SOOT_CH_URL`
  / `SOOT_CH_USER` / `SOOT_CH_PASSWORD` env knobs in soot.install,
  default them to match the docker-compose creds, and document
  in the README. **Required** before the E2E can assert anything
  about telemetry ingest.

* **Postgres "database my_iot_dev does not exist" after seed.**
  Backend logs spam this every connection-pool reconnect. `seed`
  runs `mix ash.setup` which calls `mix ash_postgres.create` and
  succeeds; the database exists when seed completes. Something
  later — possibly the dashboard, possibly an MIX_ENV split
  during `mix phx.server` — looks for the database under a
  different name or env. Not yet root-caused. Doesn't block the
  HTTP path so probably a sub-pool, but worth tracing.

* **`ash.setup` hits "type citext does not exist" on a fresh
  postgres image — resolved 2026-05-05** (see carry-over tech debt
  above). `soot.install` now ensures `"citext"` is in the consumer
  Repo's `installed_extensions/0` so the codegen step emits a
  `CREATE EXTENSION` migration ahead of the users-with-email
  migration. The `seed` stage's `psql … CREATE EXTENSION citext`
  workaround can be removed from `scripts/integration_e2e.sh`
  once a `soot` ref including this fix is in use as `SOOT_E2E_REF`.

* **Bootstrap cert path baked at compile time.** `soot_device.install`
  generates `device.ex` with
  `bootstrap_cert_path System.get_env("SOOT_BOOTSTRAP_CERT", "/etc/soot/bootstrap.pem")`.
  The DSL is evaluated at compile time, so the env var must be
  set BEFORE `mix test` triggers the test-env compile, not at
  runtime. The script's `boot-and-test` stage now sets
  `SOOT_BOOTSTRAP_CERT` / `SOOT_BOOTSTRAP_KEY` /
  `SOOT_PERSISTENCE_DIR` pointing at the seed-stage outputs so
  host `mix test` boot succeeds. Only a script-side workaround;
  the underlying brittleness (target-only paths baked at
  compile-time with no Application-config layer) lives in
  `soot_device.install`.

* **`boot-and-test` runs an empty test suite.** The big one.
  `mix test --include qemu --include e2e` runs against a
  generated `my_device` project that contains:

    - `test/my_device_test.exs` — the `mix nerves.new` boilerplate
      (one trivial test, no qemu/e2e tag)
    - `test/support/qemu.ex` — the QEMU helper module (no tests)
    - `test/test_helper.exs` — boilerplate

  `soot_device.install` scaffolds the QEMU helper but writes
  zero tests that use it. There are no `:qemu` tests, no `:e2e`
  tests, no enrollment assertion, no contract-fetch assertion,
  no telemetry-publish-and-receive assertion. **Even when this
  stage turns green, it asserts nothing about device behavior.**

  This means PR #13's E2E in its current shape is structural
  scaffolding, not validation. Getting it "green" is necessary
  but not sufficient.

  Plan, in order:
    1. Land PR #13 once the script structurally succeeds
       (no fake-green claims in the description).
    2. soot_device upstream: add an on-device test suite that
       runs from inside QEMU and validates device behavior
       *without* requiring a working backend (per project
       direction 2026-05-04).
    3. soot meta-package: add backend-paired E2E assertions
       (device enrolls → backend has cert; device publishes →
       ClickHouse row appears; device fetches contract →
       fingerprint matches). Requires the ClickHouse-creds gap
       and the resource-domain gap to be fixed first.

* **Per-library cross-repo PRs are not exercised.** The script
  resolves all `soot_*` / `ash_*` libraries through whatever SHAs
  `mix.exs` / `mix.lock` of `soot-iot/soot@<ref>` pin. A PR to e.g.
  `soot-iot/soot_core` is not tested against the umbrella until
  someone bumps the lock here. Per-library CI catches per-library
  breakage; the umbrella regression risk is uncovered.

  **Return-to plan.** Igniter's `--install <name>@github:<owner>/
  <repo>@<ref>` form already accepts a ref. A sibling-PR override
  would extend the script with a list-of-overrides input
  (env var, e.g. `SOOT_E2E_OVERRIDES="ash_pki=my-branch,soot_core=
  other-branch"`) that the script splits and threads as extra
  `--install` flags after the main `soot@github:...` install. Each
  extra install at the top level of the operator's `mix.exs` should
  win over soot's transitive github dep, though this needs
  verification — Mix doesn't auto-add `override: true` for
  duplicate github sources, so igniter may need a small change to
  emit the override keyword for top-level explicit deps. In the
  workflow, a `workflow_dispatch` input + a per-library
  `repository_dispatch` trigger from the sibling repo's CI would
  let a `soot_core` PR fire the umbrella E2E with its own branch
  pinned. Keep the override mechanism in the script — not the
  workflow — so the same override is reproducible locally
  (`SOOT_E2E_OVERRIDES=... ./scripts/integration_e2e.sh all`).

---

## README device-side Quickstart issues (2026-05-05)

Surfaced by walking the README's `## Device-side Quickstart` block
literally on a clean machine. Generation + firmware build succeed end
to end, but two of the steps as written do not work without
edits/extra commands.

* **`mix archive.install hex nerves_new` — no such Hex package.**
  README line 97. Hex returns `No package with name nerves_new (from:
  mix.exs) in registry`. The archive that provides `mix nerves.new`
  is `nerves_bootstrap` (`mix archive.install hex nerves_bootstrap`,
  installs as `nerves_bootstrap-1.15.x`). Fix the README copy. The
  consumer-facing igniter sibling is `igniter_new`, which probably
  primed the mistake — but `nerves` ships its archive under the
  `_bootstrap` suffix.

* **README's `mix compile` smoke check fails before `mix deps.get`.**
  README lines 105–108 say:

      cd my_device
      mix compile           # host build (smoke check)

      export MIX_TARGET=qemu_aarch64
      mix deps.get
      mix firmware

  In practice `mix compile` aborts immediately:

      Unchecked dependencies for environment dev:
      * duxedo (https://github.com/soot-iot/duxedo.git - main)
        the dependency is not available, run "mix deps.get"
      ** (Mix) Can't continue due to errors on dependencies

  Reason: `soot_device.install` adds `{:duxedo, github: ...}` to the
  consumer's `mix.exs` (for the generated telemetry test's local
  Duxedo capture/query) and does not run `deps.get` after patching.
  The install task's own notice block (printed at the end of
  `mix igniter.new`) tells the user to "Run `mix deps.get` once the
  install completes" — but the README's next step is `mix compile`,
  not `mix deps.get`, so a literal reader hits the failure. Two
  fixes, either is fine:
    1. Update the README so the host smoke-check is `mix deps.get
       && mix compile` before exporting `MIX_TARGET`.
    2. Make `soot_device.install` itself run a `deps.get` after the
       mix.exs patch so subsequent compiles work without operator
       intervention.

* **Igniter post-step prints `fatal: not a git repository` then a
  green ✓.** Cosmetic. When the parent directory isn't itself a git
  repo, the `Initializing local git repository, staging all files,
  and committing` step emits `fatal: not a git repository (or any
  of the parent directories): .git` from `git status` (or similar),
  then proceeds to `git init` + commit and reports ✓. Confusing
  during a first-time walkthrough; not a blocker.

* **`:emqtt.* is undefined` warnings on every compile.**
  `soot_device_protocol/lib/soot_device_protocol/mqtt/transport/emqtt.ex`
  references `:emqtt.start_link/1`, `connect/1`, `publish/5`,
  `subscribe/3`, `unsubscribe/3`, `disconnect/1` but `:emqtt` is not
  a transitive dep of the device project (it's a backend dep). On
  both host and `MIX_TARGET=qemu_aarch64` compiles, six warnings fire
  every time. Not blocking firmware build, but loud — consider
  guarding the EMQTT transport with `Code.ensure_loaded?(:emqtt)`
  or moving it behind an optional dep.
