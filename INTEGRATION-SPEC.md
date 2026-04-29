# Soot — Integration Test Specification

**Status:** Draft v1
**Audience:** Implementers landing the end-to-end CI job for the Soot
framework. Read alongside `UI-SPEC.md` (installer contract) and
`GENERATOR-SPEC.md` (per-installer file manifest); this document
specifies the proof-of-life test that runs the entire generated stack
in CI.

## 1. Purpose

`UI-SPEC.md` §9 calls for a "golden-path test" that runs `mix
igniter.new` end-to-end and asserts the seeded admin app actually
serves requests. That test is necessary but not sufficient — it
exercises the *backend installer* but not the *protocol*. The
protocol is what makes Soot a framework instead of a Phoenix
boilerplate.

This document specifies a single CI job that runs the full stack:
generated backend talking to a real broker talking to a real
QEMU-booted Nerves device. Pass criteria are wire-level behaviors
specified in `SPEC.md` §6 (enrollment, shadow, commands, telemetry,
contract refresh), not internal Ash assertions.

If this test passes, a user following the README's Quickstart from
zero can expect their bits to flow.

## 2. Principles

1. **Wire-level pass criteria.** Each assertion checks an observable
   protocol behavior — a row in `Devices` Ash resource transitioning
   to `:operational`, a published MQTT shadow message, a row in
   ClickHouse — not an internal helper return value. The test
   replicates what an operator would manually check after
   `mix phx.server` plus QEMU boot.
2. **Real services, not mocks.** Real EMQX, real Postgres, real
   ClickHouse (or the `:soot_telemetry` `:noop` writer with a counter
   assertion if ClickHouse is too heavy for CI v1). No process-level
   shims; the broker is what the device talks to.
3. **Generated code, not a checked-in fixture project.** The job
   begins by running `mix igniter.new` against the local soot path
   deps. If the generator can't produce a working app, this test
   fails. That is the whole point.
4. **One job, one report.** Splitting the test into "backend works"
   and "device works" defeats the purpose — the integration is what
   we're testing. If a stage fails, dump every relevant log
   (broker, backend, device, qemu console) into the failure report.
5. **QEMU is the canonical device target.** All hardware-specific
   targets are out of scope for CI; `qemu_aarch64` runs on every
   GitHub-hosted runner, gives a real Nerves environment, and is what
   `soot_nerves_example` already targets.

## 3. Test Topology

```
                   ┌────────────────────────────┐
                   │  GitHub-hosted runner      │
                   │  (ubuntu-latest, 2 vCPU)   │
                   │                            │
   ┌──────────┐    │  ┌──────────────────────┐  │
   │ Postgres │←───┼──┤ Generated Soot       │  │
   │ service  │    │  │ Backend (Phoenix     │  │
   └──────────┘    │  │ + Ash, mix run)      │  │
                   │  │  :4001 (mTLS https)  │  │
   ┌──────────┐    │  │  :4000 (admin http)  │  │
   │  EMQX    │←───┼──┘──────────┬───────────┘  │
   │ service  │←───────────┐     │              │
   │ :1883    │            │     │              │
   └──────────┘            │     │              │
                           │     ▼              │
                   ┌──────────────────────┐     │
                   │ QEMU (TCG aarch64)   │     │
                   │ Nerves device image  │     │
                   │ - hostfwd 4369/9100  │     │
                   │ - SootDeviceProtocol │     │
                   └──────────────────────┘     │
                                                │
                   ┌──────────────────────┐     │
                   │ Test driver process  │←────┘
                   │ (mix test on host)   │
                   │  - Ash.read! Devices │
                   │  - :rpc to QEMU      │
                   │  - Req to backend    │
                   └──────────────────────┘
```

- Postgres, EMQX (and ClickHouse, Phase 2) come up as GitHub Actions
  service containers — first-class supported, restart on failure,
  exposed via `localhost:<port>`.
- The generated backend runs as a background `mix run --no-halt`
  process owned by the test driver. The driver has the same Ash
  domain modules in its codepath (it `cd`s into the generated app)
  so it can read `Devices` directly without going through HTTP.
- QEMU runs in TCG (software) mode; no KVM needed for cross-arch
  emulation. User-mode networking (`-netdev user`) with hostfwd for
  EPMD (4369) and the pinned distribution port (9100) so the host
  test can `:rpc` into the device. The device reaches the host
  services via the QEMU gateway IP `10.0.2.2`.

## 4. Workflow Steps

The CI job is a single `integration_e2e` job in
`.github/workflows/integration.yml` in the soot repo. Steps in order:

### 4.1 Service bring-up

```yaml
services:
  postgres:
    image: postgres:16
    env:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports: ["5432:5432"]
    options: >-
      --health-cmd "pg_isready -U postgres"
      --health-interval 5s
      --health-timeout 5s
      --health-retries 10

  emqx:
    image: emqx/emqx:5.8.0
    env:
      EMQX_ALLOW_ANONYMOUS: "false"   # mTLS only; we'll push trust bundle on bring-up
    ports: ["1883:1883", "8883:8883", "18083:18083"]
    options: >-
      --health-cmd "/opt/emqx/bin/emqx ctl status"
      --health-interval 10s
      --health-retries 12

  clickhouse:
    image: clickhouse/clickhouse-server:25.3
    env:
      CLICKHOUSE_USER: soot
      CLICKHOUSE_PASSWORD: soot
      CLICKHOUSE_DB: telemetry
    ports: ["8123:8123", "9000:9000"]
    options: >-
      --health-cmd "wget --quiet --tries=1 --spider http://localhost:8123/ping || exit 1"
      --health-interval 5s
      --health-retries 12
      --ulimit nofile=262144:262144
```

ClickHouse is in scope from v1 — the test asserts that telemetry
batches the device publishes actually land as rows in
`telemetry.outdoor_temperature`, not just that
`Telemetry.IngestSession` row counts increment. The OLAP path is
half the framework's value proposition; testing it without it is
testing half the wire.

### 4.2 Tooling setup

```yaml
- run: sudo apt-get install -y qemu-system-arm
- uses: erlef/setup-beam@v1
  with: { elixir-version: "1.18.4", otp-version: "28.3.2" }
- run: mix archive.install --force hex igniter_new
- run: mix archive.install --force hex phx_new
- run: mix local.nerves.bootstrap   # installs the nerves bootstrap archive
```

### 4.3 Generate the backend app

```yaml
- name: Generate backend
  working-directory: /tmp
  run: |
    mix igniter.new soot_e2e \
        --install soot \
        --with phx.new \
        --with-args="--database postgres" \
        --yes
```

The `soot.install` umbrella composes all per-library installers (Ash,
Phoenix, ash_pki, soot_core, ash_mqtt, soot_telemetry, soot_segments,
soot_contracts, soot_admin) and emits a working router with the
`:device_mtls` pipeline. With `--example` (default per
`GENERATOR-SPEC.md`), the example shadow + outdoor-temperature stream
are also generated.

To make the install resolve against the in-tree soot rather than hex,
the workflow uses path overrides via a config file the generator
respects (planned: `--from-path /path/to/soot_workspace`). Until that
flag exists, the workflow uses a `mix.local.hex` mirror trick or
patches `mix.exs` post-generation. (Open question §10.)

### 4.4 Set up backend infrastructure

```yaml
- name: PKI + migrations + broker config
  working-directory: /tmp/soot_e2e
  env:
    SOOT_CLICKHOUSE_URL: http://soot:soot@localhost:8123/telemetry
  run: |
    mix deps.get
    mix ash_pki.init --out priv/pki                     # generate CA, server cert
    mix ash.setup                                       # ecto.create + migrate (Postgres)
    mix soot_telemetry.gen_migrations --out priv/migrations/clickhouse
    clickhouse-client --host localhost --user soot --password soot \
      --database telemetry --multiquery \
      < priv/migrations/clickhouse/V0001__telemetry.sql
    mix soot.broker.gen_config --out priv/broker        # render emqx.json + mosquitto.acl
    mix soot.contracts.build --out priv/contracts       # signed bundle
    mix soot.demo.seed                                  # tenant + 25-device batch + admin user + telemetry stream
- name: Push EMQX trust bundle + ACLs
  run: |
    # Push mTLS trust bundle to the EMQX listener via REST API
    curl -X PUT http://localhost:18083/api/v5/listeners/ssl:default \
         -d @/tmp/soot_e2e/priv/broker/emqx_listener.json
    curl -X POST http://localhost:18083/api/v5/authorization/sources \
         -d @/tmp/soot_e2e/priv/broker/emqx_acl.json
```

(EMQX trust-bundle push is a real concern; the install task may need a
new `mix soot.broker.push_emqx --url ... --api-key ...` task that
wraps these REST calls. See gap §8.)

### 4.5 Start backend

```yaml
- name: Start backend
  working-directory: /tmp/soot_e2e
  run: |
    mix run --no-halt > backend.log 2>&1 &
    echo "BACKEND_PID=$!" >> $GITHUB_ENV
    # wait for /.well-known/soot/contract to respond
    timeout 60 bash -c 'until curl -sf http://localhost:4000/.well-known/soot/contract; do sleep 1; done'
```

### 4.6 Generate device app

```yaml
- name: Generate Nerves device
  working-directory: /tmp
  run: |
    mix nerves.new soot_e2e_device --target qemu_aarch64
    cd soot_e2e_device
    mix igniter.install soot_device \
        --backend-url https://10.0.2.2:4001 \
        --bootstrap-cert ../soot_e2e/priv/pki/devices/demo-device-001.pem \
        --bootstrap-key ../soot_e2e/priv/pki/devices/demo-device-001.key \
        --serial DEMO-000001 \
        --yes
```

`soot_device.install` would scaffold the imperative-layer pipeline:
`SootDeviceProtocol.Supervisor` in the application tree, the example
shadow handler that consumes `weather_enabled`/`weather_interval_s`/`label`,
a tiny telemetry source that publishes outdoor temperature every N
seconds.

(The `mix soot_device.install` task does not exist yet — see gap §8.)

### 4.7 Build firmware

```yaml
- name: Build firmware
  working-directory: /tmp/soot_e2e_device
  env:
    MIX_TARGET: qemu_aarch64
    MIX_ENV: prod
  run: |
    mix deps.get
    mix firmware
```

Cold build: 5-15 min. Cached deps: 1-3 min. Use `actions/cache` keyed
on `mix.lock` + `nerves_system_qemu_aarch64` version.

### 4.8 Boot QEMU and connect

```yaml
- name: Boot QEMU and run integration tests
  working-directory: /tmp/soot_e2e_device
  run: |
    mix test --only e2e --include qemu
```

The actual driver is an ExUnit test (in the *generated device*
project, since it has the device app's compiled code in scope, OR in
the soot meta-package using `:rpc` only — Open question §10) that
uses the existing `SootNervesExample.Test.QEMU` helper:

```elixir
defmodule SootE2EDevice.Integration.FullStackTest do
  use SootE2EDevice.IntegrationCase
  @moduletag :qemu
  @moduletag :e2e

  test "device enrolls, publishes telemetry, reconciles shadow", ctx do
    # 1. Device boots and enrollment completes within 30s
    assert eventually(fn ->
      device = Backend.fetch_device("DEMO-000001")
      device.state == :operational and device.operational_certificate_id != nil
    end)

    # 2. Telemetry IngestSession opens and accumulates batches
    assert eventually(fn ->
      session = Backend.latest_ingest_session("DEMO-000001", :outdoor_temperature)
      session != nil and session.batch_count >= 1
    end)

    # 2b. Rows actually land in ClickHouse (not just IngestSession bookkeeping)
    assert eventually(fn ->
      Backend.clickhouse_count("outdoor_temperature", "DEMO-000001") > 0
    end)

    # 3. Shadow reconciliation: set desired via Ash, observe reported
    Backend.set_desired(ctx, "DEMO-000001", %{weather_enabled: false})
    assert eventually(fn ->
      shadow = Backend.fetch_reported(ctx, "DEMO-000001")
      shadow["weather_enabled"] == false
    end)

    # 4. Command roundtrip: backend invokes :reboot, device responds
    {:ok, response} = Backend.invoke_command(ctx, "DEMO-000001", :reboot, %{}, timeout: 10_000)
    assert response.acknowledged == true

    # 5. Contract refresh: backend rebuilds bundle, device pulls new fingerprint
    new_fingerprint = Backend.rebuild_contracts(ctx)
    assert eventually(fn ->
      qemu_rpc(ctx, SootDeviceProtocol.Contracts, :current_fingerprint, []) == new_fingerprint
    end)
  end
end
```

`eventually/1` polls every 500ms with a 30s timeout — standard
integration-test idiom. The `qemu_rpc/3` helper already exists in
`soot_nerves_example/test/support/qemu.ex`.

### 4.9 Cleanup + log dump

```yaml
- name: Dump logs on failure
  if: failure()
  run: |
    echo "::group::Backend log";  cat /tmp/soot_e2e/backend.log;            echo "::endgroup::"
    echo "::group::EMQX log";     docker logs $(docker ps -q -f ancestor=emqx/emqx:5.8.0); echo "::endgroup::"
    echo "::group::QEMU console"; cat /tmp/soot_e2e_device/qemu.log;        echo "::endgroup::"
    echo "::group::Postgres log"; docker logs $(docker ps -q -f ancestor=postgres:16); echo "::endgroup::"

- name: Stop backend
  if: always()
  run: kill $BACKEND_PID || true
```

## 5. QEMU on CI — Feasibility

**Verdict: feasible, well-trodden.**

- **Toolchain availability.** `qemu-system-aarch64` is a 50MB apt
  package on `ubuntu-latest`. Install in a single step.
- **No KVM required.** Cross-architecture emulation (host=x86,
  guest=aarch64) runs in TCG (Tiny Code Generator, software-only).
  KVM only matters for same-arch emulation. GitHub-hosted runners do
  not expose `/dev/kvm` anyway, so this is the only mode that works.
- **Boot speed.** A small Nerves `qemu_aarch64` image (no GUI, no
  graphics drivers, no excess apps) boots to a working Erlang shell
  in 20-60 seconds on a 2-vCPU runner. The existing
  `soot_nerves_example/scripts/run_qemu.sh` already documents the
  exact qemu invocation that works.
- **Firmware build cost.** This is the dominant time cost. A cold
  Nerves build pulls the buildroot toolchain (≈400MB) and assembles
  the firmware — 5-15 minutes on a 2-vCPU runner. With
  `actions/cache` on `_build`, `~/.nerves`, and the
  `nerves_system_qemu_aarch64` artifact, warm builds drop to 1-3
  minutes.
- **Memory budget.** QEMU runs with `-m 1024` (1GB guest). The
  runner has 7GB RAM, plenty for QEMU + the Postgres/EMQX containers
  + the test driver.
- **Network plumbing.** User-mode networking (`-netdev user`) needs
  no special privileges. `hostfwd=tcp::4369-:4369` exposes EPMD;
  `hostfwd=tcp::9100-:9100` exposes the pinned Erlang distribution
  port. The device reaches host services at `10.0.2.2`. All of this
  is already implemented in
  `soot_nerves_example/test/support/qemu.ex`.

**Reference precedent:** the Nerves project itself runs CI tests on
QEMU-booted images (see `nerves-project/nerves` and
`nerves_runtime` repos). The pattern is mature.

**Time budget for the full job:**

| Phase | Cold | Warm |
|---|---|---|
| Service container boot (postgres, emqx) | 15s | 15s |
| `mix igniter.new` + per-lib installers | 90s | 90s |
| `mix deps.get` + `mix ash.setup` | 60s | 30s |
| `mix soot.demo.seed` | 5s | 5s |
| `mix nerves.new` + `mix igniter.install soot_device` | 30s | 30s |
| `MIX_TARGET=qemu_aarch64 mix firmware` | 12 min | 2 min |
| QEMU boot + Erlang distribution handshake | 45s | 45s |
| Test driver assertions | 60s | 60s |
| **Total** | **~16 min** | **~5 min** |

The cold case fits inside the 6-hour GHA job limit with room to spare.
Cache discipline (separate cache key per `mix.lock` + nerves system
version) keeps warm runs fast.

## 6. Reference Patterns to Reuse

This document is mostly assembly of existing pieces:

| Pattern | Source | Reuse plan |
|---|---|---|
| EMQX docker-compose service definition | `ash_mqtt/docker/docker-compose.yml` | Lift verbatim into the `services:` block |
| Mosquitto docker-compose | `ash_mqtt/docker/docker-compose.yml` | Hold for v2 (pick EMQX for v1 — broker rules push is easier with REST) |
| `mix test --only integration` job pattern | `ash_mqtt/.github/workflows/ci.yml` | Same shape, broader scope |
| `mix ash_pki.init` + `mix soot.broker.gen_config` + `mix soot.contracts.build` mix-task chain | `soot/README.md` deployment section | Already documented; this test is the proof it works in order |
| `mix soot_device.install` + `mix soot_device_protocol.install` | `soot_device/lib/mix/tasks/`, `soot_device_protocol/lib/mix/tasks/` | Already shipping; integration test consumes them |
| QEMU launch + Erlang distribution | Does not exist yet. Build it in `soot_device/test/support/qemu.ex` (see §7). | New code — the canonical implementation lives in soot_device |

The `soot_nerves_example/` project is **not** a reference for this
work — that example was a one-off scaffold and would drift from the
generator output. The integration test must generate its device
project from scratch every run, the same way an evaluator does.
Anything that lived only in `soot_nerves_example/` needs to either
(a) move into `soot_device/test/support/` so the library owns it, or
(b) be scaffolded by `soot_device.install` into operator projects.

## 7. Where the Test Lives — and Where the QEMU Helpers Live

### 7.1 The QEMU helpers belong in `soot_device`

The `SootDevice.Test.QEMU` module — boot a Nerves QEMU image, port
forward EPMD + the pinned distribution port, wait for the device
node, expose `rpc/4` and `stop/1` — lives at
`soot_device/test/support/qemu.ex`.

Why this location:

- **`test/support/` is in `elixirc_paths(:test)`**, not in `lib/`. The
  module compiles when soot_device runs its own tests but never
  appears in the device firmware. A QEMU helper has no business in a
  Nerves rootfs.
- **soot_device's own test suite uses it.** The library tests its DSL
  expansion against a real device booted in QEMU — same helper, same
  invocation, every time. If the helper breaks, the library tests
  break, and the bug is caught at the source.
- **`soot_device.install` scaffolds a copy into the operator's
  project's `test/support/qemu.ex`** during installation. Operators
  who run the installer get the same helper for free, in the same
  location, in their own project namespace (e.g.
  `MyDevice.Test.QEMU`). Post-install, the file is operator-owned —
  the framework does not re-touch it on subsequent installs.
- **No `soot_device_test` package needed.** The DEVICE-SPEC §4
  placeholder for `soot_device_test` was for shared *runtime*
  fixtures (simulators); QEMU helpers are scaffold-time concerns
  better solved by the install task.

### 7.2 The integration test job lives in the soot meta-package

The `.github/workflows/integration.yml` workflow is in
`/home/lawik/sprawl/soot/soot/.github/workflows/`. It:

1. Generates a fresh backend project via `mix igniter.new ... --install soot --with phx.new`.
2. Generates a fresh device project via `mix nerves.new <app> --target qemu_aarch64` then `mix igniter.install soot_device`.
3. The device install scaffolds `MyDevice.Test.QEMU` into the
   generated project's `test/support/qemu.ex`. Same code as
   soot_device's own helper, namespaced to the operator's project.
4. The integration assertions run as ExUnit tests in the *generated
   device project*, using its own `MyDevice.Test.QEMU` and a
   `MyDevice.Test.Backend` (also scaffolded by the installer) to
   reach the running backend.
5. The workflow shells out to `mix test --only e2e` from the
   generated device project's directory.

This means:

- **The framework gates merges**, because the workflow lives in the
  soot meta-package.
- **The device project is generated fresh every run**, so any drift
  in the installer scaffolding fails the build — the same way it
  would fail an evaluator following the README.
- **No checked-in example project is required.** `soot_nerves_example/`
  becomes optional documentation rather than load-bearing test
  infrastructure; it can stay or go without affecting the gate.

## 8. Gaps That Block This Test

These have to land before the integration test runs end-to-end.
Listed in dependency order; struck-through items have already shipped:

1. ~~`mix soot_device.install` and `mix soot_device_protocol.install`
   don't exist.~~ **Both ship.** soot_device.install scaffolds the
   `<App>.Device` DSL module + supervision wiring;
   soot_device_protocol.install scaffolds the imperative
   `SootDeviceProtocol.Supervisor` config.
2. **`SootDevice.Test.QEMU` doesn't exist** in
   `soot_device/test/support/qemu.ex`. This is the canonical QEMU
   boot + `:rpc` helper — see §7.1 for the responsibilities. Until it
   exists, soot_device has no way to test its own DSL against a real
   device, and the install task has no helper to scaffold from.
3. **`soot_device.install` doesn't scaffold a `<App>.Test.QEMU`** into
   the operator's `test/support/qemu.ex`. Same code as the canonical
   helper (§7.1), namespaced. Without it, the integration test in the
   soot meta-package has no driver to run against the booted device.
4. **`mix soot.install` doesn't generate runtime EMQX broker config.**
   The `:device_mtls` pipeline mounts the endpoints, but `runtime.exs`
   has no `:ash_mqtt` connection settings. Operator has to write them
   by hand today. Add a `--broker emqx --broker-host ...` flag (or
   read from env) to `soot.install`'s router/runtime patch.
5. **No `mix soot.broker.push_emqx` task.** EMQX trust-bundle and ACL
   push is currently a docs-and-curl exercise. For CI, we either ship
   the task or inline the curl invocations (uglier but faster to
   land).
6. **No `--from-path` flag on `igniter.new`.** The generator pulls
   `soot` and friends from hex by default. For local dev and CI
   against unmerged work, we need a way to override path deps. Today
   this is a post-generation `sed`/`mix.exs` patch.
7. **No `mix igniter.new ... --with nerves.new` validated path.**
   `nerves.new` is a different generator (`nerves_bootstrap`); does
   `igniter.new --with` work with it? Untested. Fallback is two
   commands: `mix nerves.new <app>` then `mix igniter.install
   soot_device`. The fallback is fine for CI v1 — document it in
   GENERATOR-SPEC.md and move on.
8. **Bootstrap cert provisioning for the device.** The device needs a
   bootstrap cert + key on first boot to complete enrollment. The
   demo flow needs to either (a) bake a known-good cert into the
   firmware via `rootfs_overlay`, or (b) generate at boot and persist
   to a writable partition. The simplest CI path is (a).
   `soot_device.install` should accept `--bootstrap-cert <path>` and
   `--bootstrap-key <path>` to wire the rootfs_overlay step.
9. **ClickHouse needs a writer wired up.** `soot_telemetry`
   currently ships `SootTelemetry.Writer.Noop` as the default — it
   accepts batches and discards them, fine for unit tests, fatal for
   any assertion that rows actually appear in CH. The integration
   test must (a) configure `:soot_telemetry, :writer,
   SootTelemetry.Writer.ClickHouse` (or whatever the real writer is
   called once it lands), (b) point it at the
   `SOOT_CLICKHOUSE_URL`, (c) run `mix soot_telemetry.gen_migrations`
   and apply them via `clickhouse-client` before starting the
   backend. If the real writer doesn't exist yet, that's its own
   blocker — note it here.

Items 2, 3, 6, 8, 9 are blocking. Items 4, 5, 7 can be worked
around in v1 with shell glue (curl, env vars, cert pre-baking,
two-step gen).

## 9. Phasing

### Phase 7a — QEMU helpers in soot_device

**Scope:** items 2, 3 from §8. Foundational; everything else
depends on having a QEMU helper.

- Land `SootDevice.Test.QEMU` at `soot_device/test/support/qemu.ex`
  with the responsibilities in §7.1: `available?/0`, `boot/1`,
  `stop/1`, `rpc/4`, `firmware_image_path/0`. Use port + Erlang
  distribution; no docker, no privileged ops.
- Land at least one soot_device unit test that uses it (e.g. boot a
  trivial firmware, RPC `Application.started_applications/0`,
  assert `:soot_device` is in the list).
- Extend `soot_device.install` to scaffold a copy of `qemu.ex` into
  the operator's project at `test/support/qemu.ex` under the
  operator's namespace. Same code, namespaced. Same idempotency
  rules as every other generated file.
- Add an `assert_creates` test for the scaffolding step in
  `soot_device/test/mix/tasks/soot_device.install_test.exs`.

**Owner:** single agent. Self-contained.

### Phase 7b — Bootstrap cert + broker config

**Scope:** items 4, 5, 8 from §8. Backend and device sides need to
agree on how a fresh device gets its identity.

- `soot.install` patches `runtime.exs` with `:ash_mqtt` connection
  settings driven from env (`SOOT_BROKER_URL`, `SOOT_BROKER_CA`,
  `SOOT_BROKER_CERT`, `SOOT_BROKER_KEY`). Default broker = EMQX, port
  = 1883/8883.
- Either ship `mix soot.broker.push_emqx` (preferred, durable) or
  inline the curl in the workflow (faster, less reusable).
- `soot_device.install` accepts `--bootstrap-cert <path>` and
  `--bootstrap-key <path>` and generates a `rootfs_overlay/` entry
  that bakes the cert into the firmware.

### Phase 7c — Local end-to-end

**Scope:** prove the full flow works on a developer machine before
the CI workflow lands.

- Validate `mix igniter.new ... --with nerves.new`; if it fails,
  document the two-step fallback in `GENERATOR-SPEC.md`.
- Land a runnable script (`/home/lawik/sprawl/soot/soot/scripts/integration_e2e.sh`)
  that performs §4 steps end-to-end against a local Docker
  Postgres + EMQX. This is the developer reproducer for the CI
  workflow and the script the workflow itself shells out to.
- Bake the `--from-path` workaround (item 6 from §8) — the script
  patches mix.exs after generation to point at sibling repos.

### Phase 7d — CI

**Scope:** the `.github/workflows/integration.yml` workflow file in
the soot meta-package.

- Workflow runs every push to main and on PRs touching `lib/` or
  `priv/` of any framework lib (matrix of `paths:` filters).
- 16-minute cold budget, ~5 minutes warm.
- Cache discipline: separate caches for `_build`, `~/.nerves`,
  `~/.hex`, the buildroot artifact (keyed on
  `nerves_system_qemu_aarch64` version).
- On failure: dump backend log, EMQX log, Postgres log, QEMU console
  in collapsible groups.
- Workflow body is the §7c script with the GHA service-container
  preamble bolted on top.

### Phase 7e — Mosquitto matrix

**Scope:** broker matrix only. ClickHouse is in v1 (Phase 7d).

- Matrix the broker (EMQX vs Mosquitto) — same test, two service
  configs, two jobs. Mosquitto's lean-default story (SPEC.md §3)
  deserves CI coverage even though the framework's primary path is
  EMQX.

## 10. Open Questions

- **Path-deps for generated apps.** `mix igniter.new --from-path`
  doesn't exist. Workarounds: post-generation `sed` of mix.exs,
  symlinks under deps, or `MIX_DEP_PATH` env var. Pick one and
  document it. The local-dev story matters as much as CI; this is a
  user-facing concern that affects every framework hacker, not just
  the integration test.
- **Should the demo device's identity be pre-provisioned or
  bootstrap-then-enroll?** Pre-provisioned is simpler for CI (bake
  cert into firmware, skip the bootstrap state). Bootstrap-then-enroll
  exercises more of the protocol. Probably do bootstrap-then-enroll
  in CI v1 since enrollment is the most-likely-to-break pathway and
  cheap to test.
- **Run on every PR or nightly?** A 5-minute warm run is cheap enough
  for every PR. A 16-minute cold run on a dependency change is fine
  for `main` only. Splitting unit (PR) vs integration (main + nightly)
  is the standard pattern.
- **What does "verifies relevant behavior" really mean for shadow
  reconciliation?** The simplest assertion is "set desired, observe
  reported." More thorough: assert the device actually applied the
  change (e.g. `weather_enabled: false` causes outdoor_temperature
  publishing to stop). v1 does the simple version.
- **Mosquitto vs EMQX defaults.** SPEC.md §3 says "EMQX or Mosquitto"
  with Mosquitto as the lean default. The CI test uses EMQX because
  its REST API makes ACL/listener push scriptable. The generator
  defaults to mosquitto. Reconcile: probably default to EMQX in the
  generator's `--example` flow (CI exercises what users get), keep
  mosquitto as the explicit `--broker mosquitto` choice.
- **Naming the scaffolded helper.** The QEMU helper scaffolded by
  `soot_device.install` lands at `<App>.Test.QEMU` by default
  (`MyDevice.Test.QEMU`). A `--qemu-helper-module` flag lets
  operators override. Worth bikeshedding once: should the namespace
  be `<App>.Test.*` or `<AppWeb>.Test.*` or `<App>.QEMU` flat? The
  `Test.` infix mirrors how Phoenix puts its test helpers, so go
  with that unless someone has a strong reason.

## 11. Handoff Notes

- **Read `UI-SPEC.md` and `GENERATOR-SPEC.md` first.** This document
  assumes the per-library installer contract from those.
- **The QEMU harness in `soot_nerves_example/test/support/qemu.ex` is
  already correct.** Don't rewrite it. Add to it if you need new
  helpers; the existing port + Erlang distribution dance is the
  battle-tested part.
- **Service containers are the right primitive.** Don't try to install
  Postgres or EMQX into the runner directly — service containers are
  faster, cleaner, and supported.
- **The `--example` flag is load-bearing.** Per `GENERATOR-SPEC.md`,
  `--example` is the default and generates the exact shadow + stream
  shape the device-side example consumes. The integration test
  asserts that contract end-to-end.
- **Treat the cold-cache run as the SLA.** A 16-minute cold run on a
  dependency bump is acceptable; a 30-minute cold run is not.
  Profile and cache aggressively if the budget creeps up.
