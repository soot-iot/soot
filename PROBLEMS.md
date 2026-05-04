# Soot v0.1 — Production-Blocking Gaps

Findings from a sweep of the ten library repos under `sprawl/soot/`
looking for things v0.1 claimed shipped but that don't actually
function end-to-end. The bar: "would a real production deployment do
something useful, or does this just no-op / fail / lose data?"

Three blockers, plus context on what's already covered elsewhere and
what's verified working.

**Status as of 2026-04-29:** All three blockers resolved. See per-blocker notes below.

---

## Blockers

### 1. `SootTelemetry.Writer.Noop` is the default writer — **resolved 2026-04-29**

**Status:** Fixed across two PRs.

* `soot_telemetry@16b0b11` adds `SootTelemetry.Writer.ClickHouse`, a
  pass-through writer over the `:ch` driver. Forwards the validated
  Arrow body verbatim as `INSERT INTO <table> FORMAT ArrowStream`.
  `SootTelemetry.Application` auto-starts the connection pool when
  this writer is configured. Failed inserts log at error and surface
  as `{:error, {:clickhouse_insert_failed, _}}` so the ingest plug
  returns a 500 instead of silently dropping.
* [`soot-iot/soot_telemetry#7`](https://github.com/soot-iot/soot_telemetry/pull/7)
  flips `mix soot_telemetry.install` to write
  `config :soot_telemetry, :writer, SootTelemetry.Writer.ClickHouse`
  into the consumer's `config/config.exs`. The library's
  application-env default stays `Writer.Noop` so soot_telemetry's own
  test suite can run with zero infra; consumer projects always boot
  against ClickHouse.

Original finding for context:

`soot_telemetry/lib/soot_telemetry/writer.ex:38-44` — the only writer
implementation pattern-matches the batch shape and returns `:ok`
without doing anything. The ingest plug validates headers,
fingerprint, sequence, rate limits, and authorization, then hands the
Arrow body to a no-op. Nothing reaches ClickHouse.

Already captured in `SPEC-2.md` §3.1 / §5.1 (recast as Arrow-native
pass-through writer in Phase 7).

### 2. The entire OLTP layer is ETS-only — **resolved 2026-04-29**

**Status:** Fully resolved. Originally claimed resolved 2026-04-27
when the libraries shipped Spark `Ash.Resource` extensions + thin
`Ash.DataLayer.Ets` defaults — but a 2026-04-29 audit found that the
per-lib igniter installers (`mix <lib>.install`) didn't generate the
consumer-side AshPostgres modules or register them. A freshly
`igniter.install`-ed project still booted entirely on ETS. Five PRs
closed the gap so consumer projects boot against AshPostgres
out-of-the-box (Postgres + ClickHouse are mandatory for every soot
deployment, including dev — there is no "lightweight ETS mode"):

* [`soot-iot/soot_core#9`](https://github.com/soot-iot/soot_core/pull/9)
  — composes `ash_postgres.install` and generates six
  AshPostgres-backed consumer modules (`Tenant`, `SerialScheme`,
  `ProductionBatch`, `Device` with `AshStateMachine`, `DeviceShadow`,
  `EnrollmentToken`).
* [`soot-iot/ash_pki#8`](https://github.com/soot-iot/ash_pki/pull/8)
  — same shape, four resources (`Certificate`, `CertificateAuthority`,
  `RevocationList`, `EnrollmentToken`).
* [`soot-iot/soot_contracts#10`](https://github.com/soot-iot/soot_contracts/pull/10)
  — generates `BundleRow` + the `soot_contracts do
  certificate_authority MyApp.CertificateAuthority end` sibling
  reference.
* [`soot-iot/soot_segments#9`](https://github.com/soot-iot/soot_segments/pull/9)
  — generates `SegmentRow` and `SegmentVersion`.
* [`soot-iot/soot#9`](https://github.com/soot-iot/soot/pull/9) — adds
  `:ash_postgres` to the umbrella `mix soot.install`'s `installs:`
  list so `mix.exs` picks it up before any per-lib installer runs.

The libraries' own test suites still run against the ETS defaults;
the installer tests cover the AshPostgres path via Igniter.Test
filesystem assertions.

Original finding for context:

Every server-side resource declares `data_layer: Ash.DataLayer.Ets`.
Restart the BEAM and you lose:

| resource                        | file                                                      |
|---------------------------------|-----------------------------------------------------------|
| `SootCore.Tenant`               | `soot_core/lib/soot_core/tenant.ex:17`                    |
| `SootCore.Device`               | `soot_core/lib/soot_core/device.ex:22`                    |
| `SootCore.DeviceShadow`         | `soot_core/lib/soot_core/device_shadow.ex:17`             |
| `SootCore.EnrollmentToken`      | `soot_core/lib/soot_core/enrollment_token.ex:19`          |
| `SootCore.SerialScheme`         | `soot_core/lib/soot_core/serial_scheme.ex:27`             |
| `SootCore.ProductionBatch`      | `soot_core/lib/soot_core/production_batch.ex:13`          |
| `AshPki.CertificateAuthority`   | `ash_pki/lib/ash_pki/certificate_authority.ex:15`         |
| `AshPki.Certificate`            | `ash_pki/lib/ash_pki/certificate.ex:18`                   |
| `AshPki.RevocationList`         | `ash_pki/lib/ash_pki/revocation_list.ex:18`               |
| `AshPki.EnrollmentToken`        | `ash_pki/lib/ash_pki/enrollment_token.ex:22`              |
| `SootContracts.BundleRow`       | `soot_contracts/lib/soot_contracts/bundle_row.ex:22`      |
| `SootSegments.SegmentRow`       | `soot_segments/lib/soot_segments/segment_row.ex:12`       |
| `SootSegments.SegmentVersion`   | `soot_segments/lib/soot_segments/segment_version.ex:18`   |
| `SootTelemetry.StreamRow`       | `soot_telemetry/lib/soot_telemetry/stream_row.ex:16`      |
| `SootTelemetry.Schema`          | `soot_telemetry/lib/soot_telemetry/schema.ex:15`          |
| `SootTelemetry.IngestSession`   | `soot_telemetry/lib/soot_telemetry/ingest_session.ex:15`  |

`SPEC.md` §17 and §414 explicitly describe these as Postgres-backed:

> 2. OLTP and OLAP are separate concerns. Transactional/shadow/
> configuration state lives in Ash resources backed by Postgres (or
> SQLite for small deployments).
>
> The backend `Device` is a row in Postgres with policies,
> multi-tenancy, and certificate relationships.

But there are zero `AshPostgres` references anywhere in `soot_core`,
`soot_telemetry`, `soot_contracts`, `soot_segments`, or `soot_admin`
(verified with `grep -rn AshPostgres`).

Only `ash_pki` ships a Resource-extension pattern
(`ash_pki/lib/ash_pki/resource/certificate.ex:13`) where the consumer
brings `AshPostgres.DataLayer` themselves. The other libraries ship
concrete ETS resources with no extension hook and no config knob to
swap data layers.

`AshPki.Persistence` (`ash_pki/lib/ash_pki/persistence.ex:1-12`) is a
JSON-dump-to-disk helper *for CAs only*, framed as "lightweight
file-backed persistence for the ETS-backed demo." It does not cover
issued certs, CRLs, enrollment tokens, or anything outside `ash_pki`.

This is bigger than the Writer.Noop gap. Writer.Noop drops telemetry;
ETS-only OLTP loses every tenant, device, shadow, issued cert,
contract bundle, and segment definition on every restart.

**Not currently in `SPEC-2.md`.**

### 3. Contract bundle signing only works with software CA keys — **resolved 2026-04-28**

**Status:** Both PRs merged. HSM-backed CAs can sign bundles
end-to-end; the v0.1 phase-6 "HSM-backed CA keys shipped" claim is
now accurate.

* [`soot-iot/ash_pki#2`](https://github.com/soot-iot/ash_pki/pull/2)
  added `AshPki.KeyStrategy.sign(descriptor, body, opts)` — implemented
  for `Software` (`:public_key.sign/3`) and `Pkcs11` (engine-key
  reference). `Imported` returns `:no_signing_capability`; `KMS`
  returns `:not_implemented`. Tests cover the Software round-trip and
  add a SoftHSM2-tagged round-trip in the existing `:pkcs11`
  integration block. Merged 2026-04-28.
* [`soot-iot/soot_contracts#3`](https://github.com/soot-iot/soot_contracts/pull/3)
  rewrote `Bundle.sign_body/2` to dispatch through the new callback.
  Errors from the strategy bubble up as `ArgumentError` with the
  underlying reason; the caller no longer assumes Software-only.
  Merged 2026-04-28.

Original finding for context:

`soot_contracts/lib/soot_contracts/bundle.ex:200-209`:

```elixir
defp sign_body(%AshPki.CertificateAuthority{} = ca, body) do
  case AshPki.key_strategy(ca.key_strategy) do
    AshPki.KeyStrategy.Software ->
      {:ok, private} = AshPki.KeyStrategy.Software.private_key(ca.key_descriptor)
      :public_key.sign(body, :sha256, private)

    _other ->
      raise ArgumentError,
            "signing contract bundles requires a Software CA key in v0.1; #{ca.key_strategy} is deferred"
  end
end
```

`AshPki.KeyStrategy.Pkcs11` fully implements `sign_csr` / `self_sign`
/ `sign_crl` (`ash_pki/lib/ash_pki/key_strategy/pkcs11.ex:71-133`), so
HSM-backed CAs can issue device certs. But the contract bundle —
which is the device's actual trust anchor over the wire — can't be
signed with the HSM key. The path raises `ArgumentError`.

`SPEC.md`'s phase-6 deliverables claim "HSM-backed CA keys" shipped.
In practice an operator who configures a PKCS11 CA crashes when
publishing a bundle. The natural fix is to introduce a
`KeyStrategy.sign(descriptor, body, digest_alg)` callback (or thread
through one of the existing `sign_*` shapes) and route bundle signing
through it instead of pattern-matching on `:software`.

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
  (`publisher.ex:17-44`) — though the row lives in ETS (see
  Blocker 2).
* `SootAdmin.SegmentChart` returning SQL + column metadata instead of
  rendering charts is documented design, not a stub
  (`charts/segment_chart.ex:1-25`).
* `SootSegments` DDL / SQL emission is real and exercised
  (`soot_segments/lib/soot_segments/clickhouse/{ddl,sql}.ex`).

---

## Suggested SPEC-2 additions

* **AshPostgres seam across `soot_*`** — done (see Blocker 2 above).
  Pattern mirrors `ash_pki`: Spark extension + thin ETS default + app
  config knob, with the per-lib installers generating consumer-side
  AshPostgres modules and the umbrella `mix soot.install` ensuring
  `:ash_postgres` lands in the operator's deps. Phase 7 entry added
  in `SPEC-2.md`.
* **HSM-aware bundle signing** — done (see Blocker 3 above).
  `AshPki.KeyStrategy.sign/3` shipped in `ash_pki#2`;
  `SootContracts.Bundle.sign_body/2` was rewritten in `soot_contracts#3`.
  The hardcoded `Software` match is gone.
* **Org-wide CI hygiene wart found during this work** — every per-lib
  workflow had `pull_request: branches: [main]`, which silently skipped
  CI on stacked PRs against feature branches.
  [`soot-iot/soot_segments#7`](https://github.com/soot-iot/soot_segments/pull/7)
  merged into main without CI ever running.
  [`soot-iot/soot_segments#8`](https://github.com/soot-iot/soot_segments/pull/8)
  fixed it; nine sibling PRs (`ci/run-on-all-prs` branch in each repo)
  swept the same one-line fix across the rest. Worth adding a CI
  template-baseline note to CLAUDE.md so it doesn't reappear.

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
