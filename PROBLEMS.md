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
  postgres image.** The merged Initialize/AddAuthenticationResources
  migration generated by `mix soot.install` (since c71b037 collapsed
  the recipe to one step) creates `users` with citext email columns
  before any `CREATE EXTENSION citext`. Dev machines with a
  long-lived postgres typically already have citext loaded so the
  bug doesn't surface; the docker-compose `postgres:16` image used
  by the E2E reproducer doesn't, so `mix ash.setup` fails. The
  script's `seed` stage now pre-creates the database and runs
  `CREATE EXTENSION IF NOT EXISTS citext` directly via `psql` to
  work around it. Real fix is upstream — `ash_authentication.install`
  (or whichever installer adds the users-with-email migration)
  needs to declare `citext` as a Repo extension before any
  authentication migration emits a citext column. Cross-repo
  follow-up.

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

## README walkthrough findings (2026-05-05)

A literal run of the README "Quickstart" against `origin/main`
(`e3a5f90`) on a developer machine — `mix igniter.new`, then
`mix ash.setup`, then `mix soot.demo.seed`, then `mix phx.server`.
Generated app named `readme_iot` (mechanically identical to
`my_iot`). All findings reproduce on a clean `/tmp` and a Postgres
that has not had `citext` pre-loaded.

The headline: **the Quickstart appears to succeed end-to-end while
silently leaving the consumer DB without any soot tables**, and a
README-following operator only discovers it when something inside
`/admin/devices` (or any other resource path) actually queries the
missing tables. The pieces below combine to produce that:

* **README's `mix soot.demo.seed` is the wrong task name.** The task
  is `mix soot.seed --demo` (the seed task itself is `soot.seed` and
  takes a `--demo` flag — see `soot/lib/mix/tasks/soot.seed.ex`).
  README quickstart fails immediately at this step:

      ** (Mix) The task "soot.demo.seed" could not be found.
      Did you mean "soot.seed"?

  Fix: update `README.md` Quickstart line to
  `mix soot.seed --demo` (or rename the task to `soot.demo.seed`,
  but the install task's own next-steps output already says
  `mix soot.seed --demo`, so the README is the outlier).

* **`mix soot.seed --demo` runs *during* `mix igniter.new`, before
  the database exists.** The igniter install chain triggers the
  seed automatically as the last step. Output during install:

      ==> Soot seed starting (app: ReadmeIot)
      [debug] Creating SootCore.Tenant: …
          create  Tenant 'default'
      [error] Postgrex.Protocol failed to connect: ** (Postgrex.Error)
              FATAL 3D000 (invalid_catalog_name) database
              "readme_iot_dev" does not exist
      …(repeated × ~10 connection-pool restarts)…
      [debug] QUERY ERROR source="users" queue=5630.6ms
      INSERT INTO "users" … (after 5.6s pool wait)
          skip    Admin user — %Ash.Error.Unknown{ … connection not
                  available and request was dropped from queue
                  after 5627ms … }

  The install task's own next-steps message contradicts this — it
  says: *"`mix soot.seed --demo` will run after `mix ash.setup` to
  create the default tenant, an admin user, and 5 unprovisioned
  devices."* — but the seed actually fires first, eats a 5-second
  pool timeout per resource, and skips the admin-user step. The
  rest of the seed continues without raising. Either gate the
  auto-seed behind "ash.setup has succeeded" (preferred), or
  remove the auto-seed step and rely on the README's documented
  manual `mix soot.seed --demo` invocation.

* **Seed reports success while inserting nothing for soot resources.**
  When the operator does the recovery dance (manual `mix ash.setup`
  → manual `mix soot.seed --demo`), the seed prints:

      ==> Soot seed complete (with demo fleet).
        Tenant:           default
        Serial scheme:    DEMO- (default)
        Production batch: demo-batch-1 (5 unprovisioned devices)
        Telemetry streams: cpu, memory, disk, outdoor_temperature

  …but the only table that was actually touched is `users`. The
  log shows `[debug] QUERY OK source="users"` for the admin user;
  there is **no** `QUERY OK source="tenants"`/`"devices"`/etc.
  anywhere. Direct verification:

      $ psql readme_iot_dev -c '\dt'
                     List of relations
       Schema |       Name        | Type  |  Owner
      --------+-------------------+-------+----------
       public | schema_migrations | table | postgres
       public | tokens            | table | postgres
       public | users             | table | postgres
       (3 rows)

      $ psql readme_iot_dev -c 'SELECT count(*) FROM tenants;'
      ERROR: relation "tenants" does not exist

  The `create Tenant 'default'` etc. lines in the seed output are
  printed unconditionally regardless of whether the underlying
  `Ash.create!` actually persisted. So the seed task lies about
  what it did. Fix: emit success only after the underlying create
  call returns `{:ok, _}`; surface skips/errors loudly.

* **Root cause of the silent-empty-database state: `mix ash.codegen`
  never sees the soot consumer resources.** This is the same
  cross-repo install-chain bug already tracked above ("Generated
  consumer resources point at the library domain that doesn't
  accept them"), but the surfaced symptom on a current main
  (`e3a5f90`) walk-through is different from what that entry
  describes. The previous entry says the failure mode is
  "errors emitted at runtime during DSL verification … HTTP path
  stays up". On this run **no DSL verifier error fires anywhere**
  — neither during `mix igniter.new` compile, nor during
  `mix ash.setup`, nor during `mix soot.seed`, nor during
  `mix phx.server` boot. Instead:

  - `config :readme_iot, ash_domains: [SootContracts.Domain,
    SootSegments.Domain, SootTelemetry.Domain, SootCore.Domain,
    AshPki.Domain, ReadmeIot.Accounts, ReadmeIot.Support]` —
    library-namespaced domains only.
  - The consumer-side resources (`ReadmeIot.Tenant`,
    `ReadmeIot.Device`, `ReadmeIot.SegmentRow`,
    `ReadmeIot.BundleRow`, `ReadmeIot.Certificate`, …) declare
    `domain: SootCore.Domain` / `SootSegments.Domain` /
    `SootContracts.Domain` / `AshPki.Domain` — domains the
    operator's app does not own and which the consumer modules
    are not registered into.
  - `mix ash.codegen` walks `ash_domains`, finds the library
    domains, finds only the library's internal resources (none
    of which are AshPostgres-backed in this project), and emits
    no migrations for the operator's resources. The first
    `mix ash.setup` after `mix igniter.new` only ran the
    authentication migrations (users + tokens).
  - Re-running `mix ash.codegen --name try_again` on the
    finished project confirms the pattern: *"No changes detected,
    so no migrations or snapshots have been created."*
  - Direct Ash query against the unwired resource fails at
    runtime with `Postgrex.Error 42P01 (undefined_table)
    relation "tenants" does not exist`, exactly as you'd expect
    when Ash thinks the resource is fine but no migration ever
    created its table.

  So `allow_unregistered? true` (which `SootCore.Domain` already
  has, per the existing PROBLEMS.md table) silences the *load-time*
  error but does nothing for the *codegen-skips-the-resource*
  problem. Both layers need to be fixed: either the operator
  resources need to live under an operator-side domain that's in
  `ash_domains` (e.g. a generated `ReadmeIot.SootDomain` listing
  all ten consumer modules), or each library installer needs to
  also register its consumer resource into one of the operator's
  existing domains. The existing PROBLEMS.md entry's fix-paths
  (a) and (b) address only the runtime DSL verifier, not the
  codegen miss. Cross-repo follow-up.

* **`Spark.Error.DslError` for the `magic_link` strategy emitted
  during `mix igniter.new` compile.** Logged as `warning:` but
  it's a real DSL-verifier failure:

      warning: ** (Spark.Error.DslError) authentication ->
      strategies -> magic_link :
        When registration is not enabled for magic link
        authentication, the action:
        ReadmeIot.Accounts.User.sign_in_with_magic_link must be
        a :read action. Got an action of type: :create.

  The generated `lib/readme_iot/accounts/user.ex` has
  `magic_link do … registration_enabled? false … end`
  (line 25-27) but `:sign_in_with_magic_link` is declared as a
  `create` action (line 52) with `upsert? true`. That action
  shape is what `ash_authentication`'s magic-link installer
  emits for the *registration-enabled* mode; the consumer is
  patched to disable registration without also rewriting the
  sign-in action into the registration-disabled `read` shape
  shown in the verifier message. Compile completes (the verifier
  raises but it's caught somewhere upstream and demoted to a
  warning), so the install does not abort, but the magic-link
  sign-in flow is on shaky ground until this is fixed. Fix lives
  in soot.install's auth wiring (the same module that already
  carries the `:register_admin` patch).

* **`mix ash.setup` fails on a Postgres image without `citext`
  pre-loaded.** Already in PROBLEMS.md; reproduced on the local
  `nerves_hub_web-postgres-1` (`postgres:16`) image which had
  every other extension but not citext. Worked around by
  `psql … -c 'CREATE EXTENSION IF NOT EXISTS citext'` before
  re-running `mix ash.setup`. No new info beyond the existing
  entry, but: this hits more than just the docker-compose path.
  Any postgres install where the operator hasn't pre-created
  the extension in `template1` will hit it.

* **Generated migration file name is grotesque.** Two
  collapsed migrations land with these names:

      20260505065958_initialize_and_add_authentication_resources_and_add_magic_link_auth_and_initialize_and_initialize_and_initialize_and_initialize_extensions_1.exs
      20260505065959_initialize_and_add_authentication_resources_and_add_magic_link_auth_and_initialize_and_initialize_and_initialize_and_initialize.exs

  Each per-library installer composed into `soot.install` calls
  `ash.codegen --name initialize`, and the names get
  concatenated rather than deduped. Cosmetic only, but the
  repeated `_initialize_` segments make `git status` and any
  filesystem operation on the migrations dir noisy. Likely fix
  is in `soot.install`: pass an explicit `--name install_soot`
  to the single composed codegen run, instead of letting each
  per-library installer add its own segment.

* **Endpoints that the README implies should "just work" cannot
  be smoke-tested without sign-in.** `/admin` redirects to
  `/sign-in` (HTTP 302 → 200), `/sign-in` renders. To exercise
  the magic-link flow non-interactively requires either fishing
  the token out of `/dev/mailbox` (LiveView) or hitting the
  underlying Ash action directly. README does not document a
  CLI shortcut and the only seeded user (`admin@example.com`)
  was *skipped* during the auto-seed (see first finding) — so
  on the README's literal happy-path, there is no admin user to
  sign in as until the operator does the manual recovery
  dance. After recovery, sign-in still relies on a magic-link
  email landing in `/dev/mailbox`. Worth either: (a) seeding a
  pre-confirmed admin with a known password as a fallback for
  bootstrap, or (b) adding a `mix soot.admin.create
  --email=… --password=…` task that bypasses the magic-link
  round-trip for first-time setup.
