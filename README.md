# Soot

IoT framework on Ash.

* [`SPEC.md`](SPEC.md) — backend v0.1, shipped.
* [`SPEC-2.md`](SPEC-2.md) — backend v0.2 roadmap (hardening, OTA,
  scale-out seams).
* [`UI-SPEC.md`](UI-SPEC.md) — generator + admin UI design (igniter
  installers on top of `phx.new`).
* [`DEVICE-SPEC.md`](DEVICE-SPEC.md) — device-side libraries
  (`soot_device_protocol`, `soot_device`, `soot_device_test`).
* [`SCALING.md`](SCALING.md) — single-node ceilings and the seams that
  lift each one.

The framework is split across several repos. The `ash_*` prefix marks
libraries that stand alone outside this framework; `soot_*` marks
libraries that are framework-coupled. Each library has its own repo and
is released independently.

## Repos

| Library | Phase | Status |
|---|---|---|
| `ash_pki`              | 1   | **landed** — CA hierarchy, cert issuance/revocation, CRLs, mTLS plug, bulk import, PKCS#11 |
| `soot_core`            | 2   | **landed** — Tenant, SerialScheme, ProductionBatch, Device + state machine, EnrollmentToken, `/enroll` plug |
| `ash_mqtt` (3a)        | 3a  | **landed** — resource + shadow DSLs, Mosquitto + EMQX config generators |
| `ash_mqtt` (3b)        | 3b  | **landed** — runtime client over `:emqtt` with request/reply correlation + dispatcher |
| `soot_telemetry`       | 4   | **landed** — stream DSL, schema fingerprinting, ingest plug, rate limiter, ClickHouse DDL generator |
| `soot_segments`        | 5   | **landed** — segment DSL, MV/backfill compiler, query helpers, mix tasks |
| `soot_contracts`       | 6   | **landed** — signed contract bundles, `/.well-known/soot/contract` plug, diff tool |
| `soot_admin`           | 6   | **landed** — Cinder table configs + LiveView component shells |
| `ash_jwt`              | 6   | **landed** — standalone / opt-in escape hatch (JWT bearer-token plug; not pulled in by `:soot`) |
| `soot` (umbrella meta) | 6   | **landed** — `mix soot.install` (igniter), `mix soot.demo.seed`, `mix soot.broker.gen_config`, [`SCALING.md`](SCALING.md) |
| `soot_device_protocol` | D1+ | not started — device-side imperative implementation of the protocol. See [`DEVICE-SPEC.md`](DEVICE-SPEC.md). |
| `soot_device`          | D4  | not started — declarative DSL on top of `soot_device_protocol` |
| `soot_device_test`     | D5  | not started — fixtures + simulators for device-side tests |

## Quickstart

The fast path. Generates a fresh Phoenix project with the entire Soot
framework wired up — admin LiveView, device-facing endpoints, PKI,
broker config, ClickHouse migrations.

```sh
mix archive.install hex igniter_new
mix archive.install hex phx_new

mix igniter.new my_iot --with phx.new \
    --with-args="--database postgres" \
    --install db_connection@2.9.0,soot@github:soot-iot/soot \
    --yes

cd my_iot
mix ash.setup           # apply migrations + extension setup
mix soot.demo.seed      # optional: plant demo tenant + 25 devices + admin user
mix phx.server
```

Browse to <http://localhost:4000/admin> and sign in with the credentials
the seed task printed. Device-facing endpoints (`/enroll`, `/ingest`,
`/.well-known/soot/contract`) listen on the same port behind mTLS.

`mix igniter.install soot` is the umbrella; it composes per-library
installers (`ash_pki.install`, `soot_core.install`, `soot_admin.install`,
…) in the right order. Each transitive soot library is declared as
`github: "soot-iot/<lib>", branch: "main", override: true` in soot's
`mix.exs`, so the single `--install soot@github:…` flag drags the whole
framework in without enumerating siblings. `:ash_postgres` is declared
in `soot.install`'s `info.installs`, which adds it to the consumer's
`mix.exs` before the compose chain reaches `ash_postgres.install` —
without that, the task wouldn't be loadable (ash_postgres is an
*optional* transitive of `:ash_authentication`). See
[`UI-SPEC.md`](UI-SPEC.md) for the full design and [`UI-SPEC.md`
§4](UI-SPEC.md) for the per-installer responsibility table.

### Why the extra `--install db_connection@2.9.0`?

`soot_telemetry` depends on `:ch` (the ClickHouse driver), which pins
`db_connection ~> 2.9.0`. A fresh Phoenix project locks
`db_connection 2.10.0` via Postgrex, so `mix deps.get` fails the
moment soot is added unless the consumer constrains it back to 2.9.x.
The `--install db_connection@2.9.0` flag adds a top-level
`{:db_connection, "== 2.9.0"}` to the consumer's `mix.exs` —
restrictive enough to force re-resolution to 2.9.0 without
`override: true`. This pin can't move inside `soot.install` because
the conflict is hit at `mix deps.get` *before* soot is fetched, so
the installer's `info/2` never gets to run. Drop the flag once `:ch`
widens its constraint upstream — see <https://github.com/plausible/ch>.

## Device-side Quickstart (Nerves + soot_device)

The matching flow for the device side. Generates a Nerves project
targeting QEMU and layers `soot_device` on top:

```sh
mix archive.install hex igniter_new
mix archive.install hex nerves_new

mix igniter.new my_device --with nerves.new \
    --with-args="--target qemu_aarch64" \
    --install soot_device@github:soot-iot/soot_device \
    --yes

cd my_device
mix compile           # host build (smoke check)

export MIX_TARGET=qemu_aarch64
mix deps.get
mix firmware          # ~5–15 min cold; ~300 MB Nerves system pulled
```

The `soot_device.install` task generates `lib/<app>/device.ex` (a
declarative `SootDevice` DSL stub with the four blocks `identity`,
`shadow`, `commands`, `telemetry`) plus
`lib/<app>/soot_device_config.ex` (runtime config helper) and wires
`<App>.Device` into the supervision tree. Compile-time placeholders
(`contract_url`, `enroll_url`, `serial`) are overridden at runtime
by the config helper so the same firmware can roll across
environments.

Boot the resulting image under QEMU with the launcher in
[`soot_nerves_example`](https://github.com/soot-iot/soot_nerves_example)'s
`scripts/run_qemu.sh`, or with this one-liner:

```sh
qemu-system-aarch64 -machine virt -cpu cortex-a72 -smp 2 -m 1024 -nographic \
  -drive if=virtio,file=$(ls -t _build/qemu_aarch64_*/nerves/images/*.img | head -1),format=raw \
  -netdev user,id=net0,hostfwd=tcp::4369-:4369,hostfwd=tcp::9100-:9100 \
  -device virtio-net-device,netdev=net0
```

To talk to a backend running on the host from inside QEMU, bind the
backend to `0.0.0.0` and use the QEMU user-mode gateway address
`10.0.2.2` from the device.

## Try it locally (QEMU device + example backend)

The same Quickstart commands above, but run end-to-end against real
infrastructure (Postgres + EMQX *or* Mosquitto + ClickHouse in
Docker) plus a Nerves device booted under QEMU. The reproducer is
[`scripts/integration_e2e.sh`](scripts/integration_e2e.sh) and it
runs the README's Quickstart literally —
`mix igniter.new my_iot --with phx.new --install db_connection@2.9.0,soot@github:soot-iot/soot`
for the backend, then the matching device-side
`mix igniter.new my_device --with nerves.new --install soot_device@github:soot-iot/soot_device`
followed by a `mix igniter.install soot_device@github:...` to pass
the seed-stage bootstrap cert via `--bootstrap-cert`. **No `path:`
deps, no `mix.exs` patching.** If the README's commands regress,
this script regresses with them; that's the entire point.

EMQX and Mosquitto are split into independent runs that share only
the script and a `docker-compose.base.yml` (Postgres + ClickHouse).
Each broker has its own overlay
([`docker-compose.emqx.yml`](scripts/docker-compose.emqx.yml),
[`docker-compose.mosquitto.yml`](scripts/docker-compose.mosquitto.yml)).

### Prerequisites

* Elixir / Erlang (whatever the repo's `mix.exs` requires)
* `docker` with Compose v2 (`docker compose ...`)
* `qemu-system-aarch64` (Debian/Ubuntu: `apt install qemu-system-arm`)
* Nerves host prerequisites — see
  <https://hexdocs.pm/nerves/installation.html>

The script aborts early if any of these are missing.

### One-command run

```sh
cd soot
./scripts/integration_e2e.sh all
```

Stages run in order: `setup → gen-backend → seed → start-backend →
gen-device → build-firmware → boot-and-test → stop-backend`. Cold runs
take ~15–20 min — the first firmware build pulls a ~300 MB Nerves system;
later runs reuse the toolchain cache.

### Iterating on one piece

Each stage is independently runnable, which is the point — iterate
without re-running the whole pipeline:

```sh
./scripts/integration_e2e.sh setup           # docker compose up (base + broker overlay)
./scripts/integration_e2e.sh gen-backend     # mix igniter.new (two-step, README-aligned)
./scripts/integration_e2e.sh seed            # ash_pki.init + ash.setup + soot.demo.seed
./scripts/integration_e2e.sh start-backend   # mix phx.server (background)
./scripts/integration_e2e.sh gen-device      # mix igniter.new --with nerves.new + soot_device.install
./scripts/integration_e2e.sh build-firmware  # MIX_TARGET=qemu_aarch64 mix firmware
./scripts/integration_e2e.sh boot-and-test   # mix test --include qemu --include e2e
./scripts/integration_e2e.sh stop-backend
./scripts/integration_e2e.sh teardown        # docker compose down -v + rm tmp dirs
```

Generated projects land under `/tmp/soot_e2e/{my_iot,my_device}` —
both are real Phoenix / Nerves projects you can `cd` into and poke
at directly. Set `SOOT_E2E_KEEP_TMP=1` to preserve them across
`teardown`.

### Useful environment overrides

| var                     | default          | effect                                                              |
|-------------------------|------------------|---------------------------------------------------------------------|
| `SOOT_E2E_TMP`          | `/tmp/soot_e2e`  | Where the generated projects live.                                  |
| `SOOT_E2E_BROKER`       | `emqx`           | `emqx` or `mosquitto`. Picks the docker-compose broker overlay.     |
| `SOOT_E2E_REF`          | `main`           | Git ref for `--install soot@github:soot-iot/soot@<ref>`.            |
| `SOOT_DEVICE_E2E_REF`   | `main`           | Git ref for `--install soot_device@github:soot-iot/soot_device@<ref>`. |
| `SOOT_E2E_BACKEND_PORT` | `4000`           | Phoenix HTTP port on the host.                                      |
| `SKIP_FIRMWARE`         | (unset)          | `=1` skips the device + firmware + boot stages.                     |
| `SOOT_E2E_KEEP_TMP`     | `0`              | `=1` preserves `/tmp/soot_e2e` after teardown.                      |

Host ports default to the values the README's Quickstart assumes
(Postgres 5432, ClickHouse 8123, MQTT 1883, Phoenix 4000) so the
reproducer matches what an evaluator following the docs would
expect. If those collide with services you already run on the
host, override per-port with `SOOT_E2E_POSTGRES_PORT`,
`SOOT_E2E_MQTT_PORT`, `SOOT_E2E_CH_HTTP_PORT`,
`SOOT_E2E_BACKEND_PORT`, etc. The `setup` stage refuses to start
if any of those ports is already in use (with the exact override
knob in the error). When `SOOT_E2E_POSTGRES_PORT` differs from the
default, `gen-backend` patches the generated `config/dev.exs` and
`config/test.exs` to match, so `ash.setup` and `mix phx.server`
just work.

### Poking at the running stack

Once `start-backend` (and optionally `boot-and-test`) has run:

* Backend HTTP: <http://localhost:4000/> — `/admin` is the LiveView UI;
  the `seed` stage prints the admin credentials it created.
* Device-facing endpoints (`/enroll`, `/ingest`,
  `/.well-known/soot/contract`) sit behind the mTLS pipeline and are
  exercised from inside QEMU during `boot-and-test`.
* EMQX dashboard: <http://localhost:18083/> (admin / `soot_e2e_admin`).
* ClickHouse HTTP: <http://localhost:8123/> (`soot:soot`).
* QEMU console: the firmware boots with cookie
  `soot_nerves_example_cookie` and pins Erlang distribution to host port
  `9100`. See
  [`soot_nerves_example/README.md`](../soot_nerves_example/README.md)
  for the `Node.connect/1` recipe and the standalone launcher
  (`scripts/run_qemu.sh`) — useful when you want to boot the firmware
  without going through the e2e harness.

To iterate on the backend half only — installer chain, seeds, admin UI —
run the backend stages by hand and leave the backend up:

```sh
./scripts/integration_e2e.sh setup
./scripts/integration_e2e.sh gen-backend
./scripts/integration_e2e.sh seed
./scripts/integration_e2e.sh start-backend
# ... iterate against http://localhost:4000 ...
./scripts/integration_e2e.sh stop-backend
./scripts/integration_e2e.sh teardown
```

`SKIP_FIRMWARE=1 ./scripts/integration_e2e.sh all` runs the same
backend-half stages then stops the backend — handy for CI and for
verifying the installer chain in isolation.

## Deployment (manual reference)

The Quickstart runs all of the steps below as part of
`mix igniter.install soot` plus `mix ash.setup`. This section
documents what those tasks are doing under the hood — useful when an
installer step needs to be re-run, swapped out, or applied to a
project that did not start from `igniter.new`.

The libraries are designed to be standalone, but deploying the framework
end-to-end has a specific ordering. Each step's output is the next step's
input, so skipping or reordering generally fails loudly rather than
silently.

### One-time per environment (operator handles)

These are environmental concerns the framework does not own:

- A Postgres database for `soot_core` resources (or SQLite for small
  deployments).
- A ClickHouse instance reachable from the app, with a service user.
- An MQTT broker (Mosquitto for the lean topology, EMQX for clustering).
- TLS certificates for the broker's listener (the framework's PKI can
  issue these — see step 1).

### 1. PKI bootstrap

```sh
mix ash_pki.init --out priv/pki
```

Produces `root_ca.pem`, `intermediate_ca.pem`, server cert + key, trust
bundle, and an `ash_pki.json` manifest the other mix tasks read. Pin the
trust bundle into device firmware (or have devices fetch it later via
the contract bundle). Configure the broker's listener and the Ash app's
endpoint to require client cert verification against this trust bundle.

For per-operator certs (e.g. an admin's mTLS cert), use:

```sh
mix ash_pki.gen.cert --issuer intermediate \
                     --subject "/CN=admin/O=Example" \
                     --name admin
```

### 2. App schema migrations

Run the operator's standard Ash/AshPostgres migration:

```sh
mix ash.codegen --domains MyApp.Soot.Domain   # if generating
mix ash_postgres.migrate
```

This materializes the OLTP tables that back `soot_core` (Tenants,
Devices, Batches, …), `soot_telemetry`'s registry rows, `soot_segments`,
and `soot_contracts`'s bundle history. With ETS data layers (default in
v0.1 demos) this step is a no-op.

### 3. Broker configuration

The `:soot` meta package ships `mix soot.broker.gen_config`, the
recommended one-stop wrapper that renders both Mosquitto and EMQX
configs (plus a complete `mosquitto.conf` from the bundled template)
from a single resource list:

```sh
mix soot.broker.gen_config \
      --out priv/broker \
      --resource MyApp.Device --resource MyApp.Device.Shadow
```

Pass `--mosquitto-only` or `--emqx-only` to render just one set. The
underlying per-broker generators are also available directly if the
operator wants finer control:

```sh
mix ash_mqtt.gen.mosquitto_acl \
      --out priv/broker/mosquitto.acl \
      --resource MyApp.Device --resource MyApp.Device.Shadow
# or, for EMQX:
mix ash_mqtt.gen.emqx_config \
      --out priv/broker/emqx.json \
      --resource MyApp.Device --resource MyApp.Device.Shadow
```

Mosquitto: drop the file into the broker's `acl_file` path, reload.
EMQX: `POST` the bundle's `acl` array to
`/api/v5/authorization/sources` and the `rules` array to
`/api/v5/rules`. The mix task does not push to a live broker — that's
the operator's deploy step.

### 4. ClickHouse migrations

Order matters: telemetry tables exist before segments reference them.

```sh
mix soot_telemetry.gen_migrations \
      --out priv/migrations/V0001__telemetry.sql \
      --stream MyApp.Telemetry.Vibration --stream MyApp.Telemetry.Power

mix soot_segments.gen_migrations \
      --out priv/migrations/V0010__segments.sql \
      --segment MyApp.Segments.VibrationP95 --segment MyApp.Segments.PowerDaily

clickhouse-client --multiquery < priv/migrations/V0001__telemetry.sql
clickhouse-client --multiquery < priv/migrations/V0010__segments.sql
```

The framework intentionally does not ship a ClickHouse migration runner.
Use whatever the operator already has; the SQL is plain and idempotent
(`CREATE TABLE IF NOT EXISTS …`, `CREATE MATERIALIZED VIEW IF NOT
EXISTS …`).

### 5. Stream + segment registration (at app boot)

Once per app start, register the live modules so the in-DB rows track
them:

```elixir
def start(_, _) do
  SootTelemetry.Registry.register_all([
    MyApp.Telemetry.Vibration,
    MyApp.Telemetry.Power
  ])

  SootSegments.Registry.register_all([
    MyApp.Segments.VibrationP95,
    MyApp.Segments.PowerDaily
  ])

  Supervisor.start_link(children, opts)
end
```

A new fingerprint creates a new schema/segment version and supersedes
the previous current row. The previous row is **not deleted** — devices
referring to old fingerprints still work until the operator retires
them explicitly.

### 6. Contract bundle

```sh
mix soot.contracts.build \
      --signing-ca intermediate \
      --mqtt MyApp.Device --mqtt MyApp.Device.Shadow \
      --stream MyApp.Telemetry.Vibration --stream MyApp.Telemetry.Power \
      --crl-url https://crl.example.com/root.crl
```

Re-run this whenever **any** input changes (a topic added, a stream
schema bumped, a new CA in the trust bundle). The bundle's fingerprint
is what devices use to know they're up to date.

### 7. Endpoints

`mix igniter.install soot` mounts these in the operator's Phoenix
router under a `:device_mtls` pipeline that runs `AshPki.Plug.MTLS`
before dispatch:

```elixir
pipeline :device_mtls do
  plug AshPki.Plug.MTLS, require_known_certificate: true
end

scope "/" do
  pipe_through :device_mtls

  forward "/enroll", SootCore.Plug.Enroll               # Phase 2
  forward "/ingest", SootTelemetry.Plug.Ingest          # Phase 4
  forward "/.well-known/soot/contract",
    SootContracts.Plug.WellKnown                        # Phase 6
end
```

By default the same Bandit listener serves both the admin browser
pipeline (no client cert) and the `:device_mtls` pipeline (cert
required). The `AshPki.Plug.MTLS` plug enforces cert presence on
device routes only; admin sessions go through unchallenged. Operators
behind a TLS-terminating load balancer can flip the plug to
`header_mode: {:enabled, "x-client-cert"}` and trust the LB to inject
the verified cert. Operators wanting a hard split between admin and
device endpoints can re-run the installer with `--split-endpoints`
(planned, see [`UI-SPEC.md` §5](UI-SPEC.md)).

### 8. Explicit backfills (only when needed)

Changing a segment definition does **not** silently invalidate
historical data. Old MVs continue serving until the operator retires
them. If new metrics need history populated:

```sh
mix soot_segments.gen_backfill \
      --out priv/migrations/V0011__backfill_vibration_p95.sql \
      --segment MyApp.Segments.VibrationP95 \
      --from 2026-01-01T00:00:00Z

clickhouse-client --multiquery < priv/migrations/V0011__backfill_vibration_p95.sql
```

### Update flow (after a change)

| change                              | re-run                                                          |
|-------------------------------------|-----------------------------------------------------------------|
| New / removed device cert           | nothing in this list — the cert tables update at runtime        |
| New tenant                          | nothing — runtime                                               |
| Topic / shadow declaration changed  | step 3 (broker config), step 6 (contracts)                      |
| New `mqtt action`                   | step 3, step 6                                                  |
| Telemetry stream field added/removed| step 4 (telemetry migrations), step 5 (re-register), step 6     |
| Segment definition changed          | step 4 (segment migrations), step 5 (re-register); optionally 8 |
| CA rotated                          | step 1 (rotate), step 6 (rebuild bundle)                        |

### Production vs. development

In v0.1 every `soot_*` resource defaults to `Ash.DataLayer.Ets` for
demos. **For production, swap each resource to `AshPostgres.DataLayer`
in your operator project** (the resources are framework-coupled, but
the data layer is operator's choice). The `*_telemetry` writer also
needs to swap `SootTelemetry.Writer.Noop` for an operator-supplied
ClickHouse writer over the `:ch` driver — `Noop` accepts everything and
discards it, which is fine for tests and a footgun in prod.

## Quickstart (single-library, dev-only)

```sh
cd ash_pki
mix deps.get
mix test
mix ash_pki.init --out priv/pki
mix ash_pki.gen.cert --issuer intermediate --subject "/CN=device-001" --name device-001
```
