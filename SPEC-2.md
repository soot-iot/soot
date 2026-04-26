# Soot — Backend Roadmap (post-v0.1)

**Status:** Draft v1
**Audience:** Library implementers (continuing where `SPEC.md` left off)
**Companion:** `DEVICE-SPEC.md` — device-side libraries that consume the
contract bundle.

## 1. Scope

`SPEC.md` defined v0.1 of the backend across phases 1–6. Every deliverable
named there has shipped: PKI, tenants/devices/state machine, MQTT DSL +
runtime, telemetry, segments, contracts, admin, JWT escape hatch,
umbrella generator, scaling-cliff doc, HSM-backed CA keys, bulk
pre-provisioned cert import.

This document covers v0.2: hardening the hot path, the operational
features the original spec deferred to "open questions", and the
scale-out edges the original spec called "documented, not built".

It does **not** redesign anything in v0.1. Where a v0.1 surface needs
extending, the extension preserves backwards compatibility unless an
explicit migration is called out.

## 2. Principles (carried over)

The five principles from `SPEC.md` §2 still hold. Two emphases for v0.2:

* **Don't backslide on lean by default.** Hardening means more knobs,
  not more required infrastructure. Every new dependency is opt-in
  and called out.
* **Keep escape hatches honest.** The imperative-equals-implementation
  rule from `SPEC.md` §2.7 applies in both directions: if a v0.2
  feature is exposed only through a DSL, the underlying primitive
  must also be operator-accessible.

## 3. Themes

Three orthogonal themes. Each phase (§7) draws from one or more.

### 3.1 Hardening the hot path

v0.1's ingest, MQTT runtime, and bundle endpoints are correct on the
golden path and reject the documented error branches, but several
production-grade behaviors are stubs or absent:

* `SootTelemetry.Writer.Noop` is the default writer. Production needs
  a real ClickHouse writer over the `:ch` driver, with batching,
  back-pressure, and retry semantics that the in-memory `Noop`
  doesn't model.
* The ingest plug treats the request body as opaque bytes. Real Arrow
  IPC framing decode lets us validate column shape against the
  declared schema before insert (rather than only relying on the
  fingerprint header).
* `AshMqtt.Runtime.Client` has no reconnect or backoff. The operator
  wraps it in a `Supervisor` for restart but a misbehaving broker
  produces a tight reconnect loop.
* `SootContracts.Plug.WellKnown` serves bundles immutably-cached but
  has no rate limit; a misbehaving device fleet can hammer it.

### 3.2 Operations features

The original spec §9 listed open questions; v0.2 picks the ones that
need framework-level support rather than operator-level configuration:

* **CBOR as a first-class default** for MQTT control payloads where
  the rule engine doesn't need to introspect.
* **Shadow conflict resolution** beyond per-top-level-key last-write-
  wins. AWS / Azure both have nuanced rules; we won't match either,
  but operators need a knob better than "last write wins" for cases
  like firmware version pinning.
* **OTA integration** through NervesHub. The contract bundle already
  carries trust material; OTA is the missing piece.
* **Time-sync drift handling.** Dual timestamps (device-reported +
  server-ingest) are baked in already; what's missing is a policy
  knob for what to do when the drift exceeds a threshold.
* **Edge gateway pattern.** Devices behind a gateway that aggregates
  and forwards. The contract model needs to accommodate this; a
  concrete sketch lives in §5.4.
* **JWKS-aware JWT signer** in `ash_jwt` so JWTs can be verified
  against an issuer's published JWKS without a static configured key.

### 3.3 Scale-out (documented in v0.1, built in v0.2)

`SPEC.md` §3 listed the lean topology's scaling exits as "documented,
not built". `SCALING.md` walks the ceilings; v0.2 builds the seams:

* **Separate ingest service** consuming the same `soot_telemetry`
  policy projection. The Writer behavior is the entry point; what's
  missing is a stable wire format between the Elixir app and a
  Rust/Go ingest service.
* **EMQX cluster API push.** v0.1 emits the JSON; v0.2 ships the HTTP
  client that pushes it to a cluster's REST endpoint.
* **Optional Kafka/Redpanda layer** between ingest and ClickHouse for
  replay and stream processing.
* **Read-replica routing** for the admin UI.
* **ClickHouse tiered storage** policy generation from segment
  retention declarations.

## 4. Library-by-library v0.2 backlog

A condensed view of every "non-goals for v1" item from `SPEC.md` §5,
re-classified as in-scope / deferred / dropped for v0.2.

### 4.1 `ash_pki`

| item                                                  | v0.2  | notes                                          |
|-------------------------------------------------------|-------|------------------------------------------------|
| Cross-CA federation                                   | defer | low demand without specific operator ask       |
| Certificate transparency log integration              | defer | regulatory; out-of-band today                  |
| Automated ACME issuance                               | in    | for the Ash app's own server cert              |
| OCSP responder                                        | in    | as an opt-in plug; many fleets prefer CRL only |
| Pre-provisioned import for ATECC manifest format      | in    | one-line vendor parser on top of `Bulk.import_csv` |
| Pre-provisioned import for OPTIGA Trust M             | in    | same                                           |

### 4.2 `soot_core`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| Device-to-device relationships                        | defer (use `Segment` + per-device commands) |
| Fleet-wide actions                                    | in (bulk command issue via `Plug.Enroll`-style endpoint) |
| Audit log via `ash_paper_trail`                       | in (already recommended in §8.2; promote to default) |

### 4.3 `ash_mqtt`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| Reconnect / backoff in `Runtime.Client`               | in   |
| Topic aliases optimisation                            | defer (low value at framework level) |
| Custom QoS upgrade / downgrade flows                  | defer |
| Sticky session management beyond MQTT 5 defaults      | defer |
| Per-tenant broker isolation (sharded brokers)         | in (drives the `BrokerConfig` per-tenant emission) |
| Live EMQX dashboard push (`POST /api/v5/...`)         | in   |

### 4.4 `soot_telemetry`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| Real Arrow IPC framing decode in `Plug.Ingest`        | in   |
| ClickHouse `:ch`-driver writer (default, replaces `Noop`) | in |
| Automatic backfill on schema change                   | defer (keep explicit per `SPEC.md` §5.4) |
| Multi-region replication coordination                 | in (via `Distributed` table generation in DDL) |
| Tiered storage / cold storage automation              | in (storage-policy emission from retention) |
| Per-tenant rate-limit federation across nodes         | in (Redis-backed limiter behind the same `take/3` API) |

### 4.5 `soot_segments`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| Ash-filter compiler over `Device` for the `:filter` field | in (replace `raw_where` for the simple cases) |
| Cross-segment joins                                   | defer |
| Ad-hoc segment creation via UI                        | defer |
| Segment definitions over non-telemetry resources      | defer |

### 4.6 `soot_contracts`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| Real Arrow IPC schema files instead of canonical JSON | in   |
| Schema-migration negotiation in the bundle            | in (devices fetching the bundle pick the version they support) |
| Asset compression / delta updates                     | defer |
| Bundle rate-limit on the well-known plug              | in   |

### 4.7 `soot_admin`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| Built-in chart renderer                               | defer (operator picks JS lib) |
| Real-time fleet map                                   | defer |
| Device console (SSH-like terminal)                    | defer |
| Event timeline panel (state-machine transitions, cert events) | in |

### 4.8 `ash_jwt`

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| JWKS fetcher with cache + rotation                    | in   |
| OIDC client surface                                   | defer |
| Refresh-token mechanics                               | defer (out of scope; operator's IdP) |

### 4.9 `soot` (umbrella)

| item                                                  | v0.2 |
|-------------------------------------------------------|------|
| `mix soot.demo` with simulated devices                | in   |
| Real-world performance benchmark suite                | in (drives `SCALING.md` numbers) |
| Migration paths for breaking changes                  | in (tied to schema-fingerprint negotiation) |

## 5. Detailed designs

The big-ticket items get a sketch here. Smaller backlog items live in
the per-library matrices above and don't need design docs at this
level.

### 5.1 ClickHouse writer (replaces `Noop`)

`SootTelemetry.Writer.ClickHouse` (new module, opt-in via the existing
`config :soot_telemetry, :writer, …` knob). Implements the `Writer`
behavior with:

* A pool of `:ch` connections sized via `:pool_size` (default 4).
* A bounded mailbox per connection; ingest plug calls `write/1`
  asynchronously under the hood, with the synchronous `:ok` returned
  once the batch is enqueued.
* Per-stream batch coalescing: configurable max-rows / max-time
  thresholds before flushing.
* Back-pressure: when every connection's mailbox is full,
  `write/1` returns `{:error, :back_pressured}` and the ingest plug
  surfaces 503 + Retry-After. The rate limiter handles the
  steady-state; back-pressure handles burst-storm corner cases.
* Retry on transient ClickHouse errors (server-restart, deadlock)
  with exponential backoff capped at 30s; permanent errors
  (column-mismatch, schema-not-found) bypass the writer and surface
  to the plug.

The writer is deliberately separate from the ingest plug so a future
out-of-process ingest service can reuse it.

### 5.2 Arrow IPC decoding in `Plug.Ingest`

Today the body is opaque bytes. v0.2 decodes the IPC framing to the
extent needed to:

1. Verify the inbound batch's schema matches the active schema's
   fingerprint (we already check the header but can now validate the
   actual column types).
2. Reject batches whose row count is wildly inconsistent with the
   declared sequence range.
3. Project server-set fields (`ingest_ts`, `tenant_id`) without
   round-tripping through a buffer.

The Elixir Arrow ecosystem is thin; v0.2 picks the implementation
based on what's healthiest at the time. Two candidates:

* `:explorer` (DataFrame-shaped); transitively pulls Polars, heavy.
* Hand-rolled IPC framing decoder over `:flatbuffers` + record
  decoding into Erlang terms. Lean, but more upfront work.

Decision deferred to the implementation phase; the writer behavior's
seam is what isolates this choice.

### 5.3 OTA via NervesHub

The contract bundle already serves the trust chain. NervesHub
integration adds:

* `SootCore.Device.firmware_version` / `firmware_target` attributes
  populated by the device on every shadow update.
* `mix soot.ota.publish --firmware <fwup> --to <segment>` — pushes a
  firmware artifact to NervesHub scoped to a `SootSegments.Segment`
  (so the operator can target "all temperature sensors in tenant
  acme" without reproducing fleet-membership logic).
* `SootAdmin.OTAPanel` — Cinder-backed table of in-flight
  deployments, with rollout progress and failure-rate column.

Out of scope: building a NervesHub-alternative. NervesHub does this
job well; we wire to it.

### 5.4 Edge gateway pattern

A device behind a gateway that aggregates and forwards traffic.
Concretely:

* The gateway holds an mTLS identity issued by the framework.
* Behind the gateway, devices may use any local link (BLE, Modbus,
  serial) and the gateway translates.
* From the framework's perspective, the gateway *is* the device for
  identity and rate-limiting purposes; for telemetry it's a
  forwarder of N inner devices.

The contract bundle gains an optional `gateway` section that names
the inner-device serial mapping. The ingest plug accepts a batch with
a different `device_id` server-set field per row provided the row's
`device_id` is a known inner device of the authenticated gateway.

This is mostly a `soot_core` + `soot_telemetry` change; no new
library is introduced.

### 5.5 Shadow conflict resolution

v0.1's `SootCore.DeviceShadow` does last-write-wins per top-level key.
v0.2 adds an optional per-key strategy:

* `:last_write_wins` (default — current behavior)
* `:device_authoritative` (server can read but not overwrite this
  key — useful for sensor calibration that lives on the device)
* `:server_authoritative` (device proposes via reported, server
  vetoes via desired — useful for firmware-version pinning)
* `:monotonic` (only larger / later values accepted — useful for
  uptime counters)

Strategies are declared on the `mqtt_shadow` extension at compile
time; the runtime dispatches on the per-attribute strategy when
processing reported updates.

### 5.6 Verified-header plug variant — production hardening

`AshPki.Plug.MTLS` already accepts `header_mode: {:enabled, "x-client-cert"}`.
v0.2 hardens this:

* Require the LB to additionally set a `x-client-verify` header
  (matching standard nginx / haproxy convention) and reject when it
  doesn't say `SUCCESS`.
* Optional `:trusted_proxy_ips` allowlist that 403s any request whose
  `remote_ip` isn't in the list (defence in depth against header
  spoofing if the upstream LB is bypassed).
* Single startup warning logged at info level if header_mode is
  enabled outside `:dev`/`:prod` matched config.

### 5.7 Schema-migration negotiation in contract bundles

`soot_telemetry` already versions schemas; the ingest endpoint already
rejects mismatched fingerprints. v0.2 adds device-side negotiation:

* The contract bundle carries `streams/<name>.json` with the active
  fingerprint; today devices either match or refetch.
* v0.2 adds `streams/<name>.versions.json` listing every fingerprint
  the backend will accept for ingest, sorted newest-first.
* Devices that haven't yet been firmware-updated to the new schema
  can keep ingesting against the previous fingerprint as long as it's
  in the accepted list.
* When the operator retires an old fingerprint, the bundle drops it
  from the versions file and the ingest plug starts rejecting that
  fingerprint with the existing 409 + hint URL.

Backwards compatible: devices that don't read `versions.json` keep
seeing the same `streams/<name>.json` and behave as today.

## 6. Non-goals for v0.2

These are NOT in scope for v0.2 and shouldn't be slipped in:

* MQTT 3.1.1 fallback. The framework is MQTT-5-only and that's a
  conscious choice.
* HSM-managed device keys *generated* through ash_pki (still
  externally provisioned via `pkcs11-tool`).
* Cross-cloud / cross-region active-active deployments. v0.2 covers
  multi-region read replicas; active-active is its own design phase.
* A managed-cloud variant of any of the libraries.
* Replacing AshPostgres as the OLTP default.

## 7. Build phases (v0.2)

Each phase produces a working improvement on top of v0.1. Phases sized
to fit a single instance unless noted; all assume the v0.1 baseline at
HEAD of each repo.

### Phase 7 — Hot-path hardening

* `SootTelemetry.Writer.ClickHouse` with `:ch` driver, batch coalescing,
  back-pressure surface to the plug.
* `Plug.Ingest` body decoding to the extent needed for type validation
  + server-set field projection.
* `AshMqtt.Runtime.Client` reconnect + backoff via a small state
  machine (idle → connecting → connected → backoff with capped
  exponential delay).
* `SootContracts.Plug.WellKnown` rate limit (per cert fingerprint).
* `AshPki.Plug.MTLS` verified-header production hardening (§5.6).

Demo target: a synthetic load test against ClickHouse that drives the
ingest endpoint above v0.1's stated ceiling and stays stable.

### Phase 8 — Operations

* `ash_jwt` JWKS fetcher.
* `soot_core` shadow per-attribute strategy (§5.5).
* `soot_segments` Ash-filter compiler for the simple `:filter` cases.
* `soot_contracts` schema-migration negotiation (§5.7).
* `soot_admin` event timeline panel.
* OTA via NervesHub (§5.3).

### Phase 9 — Scale-out seams

* Out-of-process ingest service wire format (Protobuf or Arrow Flight,
  decided in implementation).
* Live EMQX cluster API push.
* ClickHouse `Distributed` + `ReplicatedMergeTree` DDL emission
  derived from `clickhouse do …` config.
* Edge-gateway pattern in `soot_core` + `soot_telemetry` (§5.4).
* Read-replica routing in `soot_admin`.

### Phase 10 — Polish + benchmarks

* `mix soot.demo` with simulated devices.
* Performance benchmark suite that drives `SCALING.md`'s numbers from
  measured data instead of envelopes.
* Per-library `CHANGELOG.md` and a v0.2 release across every package.

## 8. Cross-cutting

### 8.1 Backwards compatibility

Every v0.2 surface preserves the v0.1 API. Where a default changes
(e.g. `SootTelemetry.Writer` flipping from `Noop` to ClickHouse if the
operator configured a database URL), the change is opt-in or detected
from configuration that didn't exist before. No silent semantic
flips.

### 8.2 Migration paths

Each library's `CHANGELOG.md` lists the explicit migration step for
breaking changes. v0.2 is largely additive; the only known migration
is the writer-default flip in `soot_telemetry`, which an operator
opts into by configuring `:writer`.

### 8.3 Testing

Same rules as v0.1: tests ship with features. Phase 9 adds an
integration-test suite that runs against real Mosquitto + EMQX +
SoftHSM2 + ClickHouse via testcontainers, gated behind an
`:integration` tag so dev loops stay fast.

## 9. Open questions (defer past v0.2)

Carried-over open questions from `SPEC.md` §9 that are explicitly
*not* picked up in v0.2:

* CBOR vs JSON default for control payloads. Make it a knob in v0.2,
  pick a default in v0.3 once we have field data.
* Cross-tenant device handoff (manufacturing-line tenant → operator
  tenant). Pre-provisioned import covers static cases; dynamic
  handoff is its own design phase.
* Self-hosted JWKS issuer (vs. relying on the operator's IdP).
* Compute-pushdown of segment queries to ClickHouse for live admin
  charts vs. batched export.

## 10. Handoff notes

Same conventions as `SPEC.md` §10:

* Read this entire document before starting your phase.
* Each phase has a one-page scope/non-goals derivation; stick to it.
* Multi-tenancy is mandatory; never weaken policy primitives.
* The contracts bundle remains the device interface — every v0.2
  surface that affects devices must round-trip through the bundle.
* Tests ship with features.
* Document the scaling cliff as you build — `SCALING.md` is a living
  document.
