# Soot

IoT framework on Ash. See [`SPEC.md`](SPEC.md) for the full design.

The framework is split across several repos. The `ash_*` prefix marks
libraries that stand alone outside this framework; `soot_*` marks
libraries that are framework-coupled. Each library has its own repo and
is released independently.

## Repos

| Library | Phase | Status |
|---|---|---|
| `ash_pki`              | 1   | **landed** — CA hierarchy, cert issuance/revocation, CRLs, mTLS plug, mix tasks |
| `soot_core`            | 2   | **landed** — Tenant, SerialScheme, ProductionBatch, Device + state machine, EnrollmentToken, `/enroll` plug |
| `ash_mqtt` (3a)        | 3a  | **landed** — resource + shadow DSLs, Mosquitto + EMQX config generators |
| `ash_mqtt` (3b)        | 3b  | not started — runtime client (planned: `:emqtt`) for action invocation over MQTT 5 |
| `soot_telemetry`       | 4   | **landed** — stream DSL, schema fingerprinting, ingest plug, rate limiter, ClickHouse DDL generator |
| `soot_segments`        | 5   | **landed** — segment DSL, MV/backfill compiler, query helpers, mix tasks |
| `soot_contracts`       | 6   | **landed** — signed contract bundles, `/.well-known/soot/contract` plug, diff tool |
| `soot_admin`           | 6   | **landed** — Cinder table configs + LiveView component shells |
| `ash_jwt`              | 6   | **landed** — standalone / opt-in escape hatch (JWT bearer-token plug; not pulled in by `:soot`) |
| `soot` (umbrella meta) | 6   | **landed** — `mix soot.new`, `mix soot.broker.gen_config`, [`SCALING.md`](SCALING.md) |

## Deployment

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

The Ash app's Phoenix / Bandit pipeline mounts (in this order, all
behind a shared `AshPki.Plug.MTLS`):

```elixir
forward "/enroll", to: SootCore.Plug.Enroll          # Phase 2
forward "/ingest", to: SootTelemetry.Plug.Ingest     # Phase 4
forward "/.well-known/soot/contract",
  to: SootContracts.Plug.WellKnown                   # Phase 6
```

For dev / demos these can run on Bandit directly with the
`server_chain.pem` + `server_key.pem` from `priv/pki/`. Production
typically terminates TLS at a load balancer; in that case use
`AshPki.Plug.MTLS` in `header_mode: {:enabled, "x-client-cert"}` and
trust the LB to inject the verified cert.

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
