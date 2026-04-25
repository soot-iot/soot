# Soot — IoT Framework on Ash — Specification

**Status:** Draft v1
**Audience:** Library implementers (including Claude Code instances picking up phase work)

## 1. Purpose

A framework and library set for building IoT systems on Elixir + Ash that enshrines best practices as defaults: MQTT with mTLS, a clean OLTP/OLAP split, factory provisioning with proper PKI, and analytical rollups over fleet segments.

The system developer using this framework builds a normal Ash application. They get device, tenant, certificate, telemetry stream, and segment resources out of the box, plus a Cinder-based admin UI to drop into their own Phoenix LiveView app, plus generated broker config and ClickHouse migrations. They keep all of Ash's flexibility for their domain-specific resources.

This spec covers the **backend** in detail. Device-side libraries are sketched at the architecture level only; they will be specified separately once the backend stabilizes.

## 2. Principles

1. **Lean by default, scalable by design.** A small operator should be able to stand the system up with one Elixir app, one broker (EMQX or Mosquitto), and ClickHouse — nothing else mandatory. The architecture must not foreclose scaling out (separate ingest service, sharded broker, etc.) but must not require it.
2. **OLTP and OLAP are separate concerns.** Transactional/shadow/configuration state lives in Ash resources backed by Postgres (or SQLite for small deployments). Telemetry lives in ClickHouse. They are bridged by explicit contracts, not by trying to make one tool do both jobs.
3. **mTLS is the identity foundation.** Same CA, same certs, same revocation story for MQTT and for the Arrow ingest endpoint. No cloud-vendor-specific plumbing in the default path.
4. **The BEAM is not on the telemetry hot path** *as a default*, but the lean topology lets the Elixir app handle ingest directly until volume justifies a separate service. The framework supports both without rewrites.
5. **Backend declares contracts; devices and infrastructure consume them.** Topic patterns, payload schemas, command envelopes, shadow shapes, and ClickHouse DDL are all derived from Ash resource definitions. One source of truth, multiple generated artifacts. On the device side, the declarative layer (Ash DSLs) configures and orchestrates the imperative layer (working MQTT/shadow/command/telemetry/contract-refresh implementations) — they are not parallel paths but the same machine accessed through different interfaces.
6. **Ash extensions, not bespoke runtime.** Each library is an Ash extension or generates Ash resources, in the spirit of `ash_authentication`. Users can override, customize, and ignore pieces.
7. **Escape hatches are first-class.** High-level Ash DSLs are the golden path; underlying imperative primitives are not "lower-level alternatives" but the actual implementation, documented and usable directly for users who need them.

## 3. Default Topology

```
                        ┌──────────────────────────┐
                        │    Operator's Phoenix    │
                        │     LiveView app         │
                        │  (Cinder admin views)    │
                        └────────────┬─────────────┘
                                     │
   ┌─────────┐  mTLS MQTT   ┌────────▼─────────┐    TLS    ┌────────────┐
   │ Devices │◀────────────▶│ EMQX / Mosquitto │           │ ClickHouse │
   └────┬────┘              └────────┬─────────┘◀────┬─────└────────────┘
        │                            │ broker          │
        │ mTLS HTTP/2 (Arrow)        │ rules /         │ TLS, service user,
        │                            │ webhooks        │ generated DDL
        │                            │                 │
        ▼                            ▼                 │
   ┌────────────────────────────────────────────────┐  │
   │           Operator's Ash Application           ├──┘
   │  (ash_pki, soot_core, ash_mqtt,             │
   │   soot_telemetry, soot_segments)         │
   └────────────────────────────────────────────────┘
```

- **Devices** authenticate to broker and ingest endpoint with the same mTLS identity.
- **MQTT** carries commands, shadow updates, alerts, and low-volume events. JSON or CBOR payloads where rule-engine introspection helps; opaque payloads where it doesn't.
- **Arrow ingest endpoint** is hosted by the Ash app itself in the lean topology. Long-lived HTTP/2 connections per device, Arrow IPC batches over the wire, bulk-inserted into ClickHouse via the `ch` driver (native protocol).
- **Broker rules / webhooks** push semantically meaningful events (alerts, state transitions) back into the Ash app over HTTP for normal action handling.
- **ClickHouse** is reached via TLS with a single service user from the Ash app. Per-device authorization happens in the app before insert; ClickHouse does not need per-device identity.
- **Admin UI** is composed by the operator using Cinder components shipped by `soot_admin`, hosted in their own Phoenix LiveView app.

### Scaling exit (documented, not built)

- Separate Rust/Go ingest service consumes the same `soot_telemetry` policy projection and writes to ClickHouse directly.
- Broker scaled horizontally (EMQX cluster) with rule definitions pushed via admin API.
- Optional Kafka/Redpanda layer for replay and stream processing.

The framework does not ship these. It ships the contracts that make them swappable.

## 4. Library Map

The `ash_*` prefix is reserved for genuinely independent Ash extensions — packages that make sense outside this framework and could be picked up standalone. The `soot_*` prefix marks packages that are part of the integrated Soot solution and presume the rest of the stack. Two packages cross that line as standalone Ash extensions; everything else is Soot.

| Library | Role | Depends on |
|---|---|---|
| `ash_pki` | CA hierarchy, cert issuance, revocation, HSM/import strategies | Ash |
| `soot_core` | Device, Tenant, SerialScheme, ProductionBatch, Enrollment; state machine; multi-tenancy primitives | `ash_pki` |
| `ash_mqtt` | MQTT as Ash transport; resource extension; broker config generation | Ash |
| `soot_telemetry` | Telemetry.Stream, Telemetry.Schema, Arrow ingest endpoint, ClickHouse DDL generator | `soot_core` |
| `soot_segments` | Segment resource; rollup compilation to ClickHouse materialized views | `soot_telemetry` |
| `soot_contracts` | Contract bundle generator (descriptors consumed by device libraries) | `soot_core`, `ash_mqtt`, `soot_telemetry` |
| `soot_admin` | Cinder table configs and LiveView components for IoT resources | `soot_core`, `soot_telemetry`, `soot_segments` |
| `soot` | Umbrella/meta-package: defaults, mix tasks, broker templates, demo | all of the above |

### Boundary notes

- **`ash_pki` is independent of IoT.** It deals in CAs, certs, keys, revocation. Reusable outside this framework.
- **`ash_mqtt` is independent of IoT.** It is "MQTT as Ash transport," analogous to `ash_graphql`. Topic conventions for IoT live in `soot_core`.
- **`soot_telemetry` and `soot_segments` are split** because telemetry ingest and analytical rollups have different lifecycles. Some users want telemetry without rollups.
- **`soot_contracts` is the single source of "what does the device need to know"** — it consumes the resource definitions from the other packages and emits language-agnostic descriptor bundles. This is where the device-side and backend-side meet. No shared runtime code.
- **`soot_admin` provides building blocks, not a finished app.** The operator drops Cinder tables and LiveView components into their own Phoenix application. Hard-coding the admin UI route structure or auth into the framework is out of scope.

## 5. Backend Libraries — Detailed

### 5.1 `ash_pki`

**Resources (generated, customizable like `ash_authentication` user resource):**

- `CertificateAuthority` — root or intermediate CA. Attributes: name, role (root/intermediate), parent, key strategy, validity, status.
- `Certificate` — issued certificate. Attributes: subject, SAN, serial, issued_by, valid_from/to, status, revocation_reason, revoked_at, fingerprint, key_strategy.
- `RevocationList` — generated CRLs with publication metadata.
- `EnrollmentToken` — short-lived bootstrap credential (covered jointly with `soot_core`).

**Key strategies (extension point, mirroring `ash_authentication` strategy pattern):**

- `:software` — keys generated and stored encrypted in DB (default for dev/testing and small fleets).
- `:pkcs11` — keys in HSM via PKCS#11 (deferred; design interface now).
- `:kms` — keys wrapped by cloud KMS (deferred; design interface now).
- `:imported` — keys never leave the device (pre-provisioned silicon: ATECC, OPTIGA, EdgeLock). Backend stores the public cert chain and trusts the chain of custody from the silicon vendor. Critical for Phase 6.

**Actions:**

- `issue_certificate` — sign a CSR with a given CA, with policy hooks for naming conventions.
- `revoke_certificate` — mark revoked, schedule CRL regeneration.
- `import_certificate` — for pre-provisioned devices.
- `rotate_ca` — generate new intermediate, cross-sign window.
- `publish_crl` — regenerate and publish CRL artifact.

**Mix tasks:**

- `mix ash_pki.init` — generate root CA, intermediate, server cert for the Ash app and the broker, configure trust store. Ten-minute path from clean repo to working mTLS.
- `mix ash_pki.gen.cert` — issue a cert for a named subject.

**Plug:**

- `AshPki.Plug.MTLS` — terminates mTLS on Bandit, validates peer cert chain against the trust store, exposes the verified cert as actor context to Ash policies. Configurable to also accept verified-header mode (with explicit warnings about header trust hygiene) for deployments behind a TLS-terminating LB.

**Non-goals for v1:** cross-CA federation, certificate transparency log integration, automated ACME issuance.

### 5.2 `soot_core`

**Resources:**

- `Tenant` — top-level isolation boundary. Used for SAN/CN conventions, topic prefixes, ClickHouse row policies. Required from the start; multi-tenancy retrofitted is painful.
- `SerialScheme` — describes serial number format. Configurable: prefix (tenant/region/SKU), batch component, sequence, optional check digit (Luhn or custom). Validates serials on creation.
- `ProductionBatch` — manufacturing batch. Bulk-creates Devices in `:unprovisioned` state. CSV import action for the manufacturing line.
- `Device` — the unit. Attributes: serial, tenant, model, batch, status, current_certificate_id, shadow (jsonb or related resource), last_seen_at, metadata.
- `EnrollmentToken` — single-use bootstrap credential. Attributes: token (hashed), device_id (or batch for bulk), valid_until, used_at.

**Device state machine** (using `AshStateMachine`):

```
unprovisioned → bootstrapped → operational ⇄ quarantined
                                    ↓
                                 retired
```

- `unprovisioned`: in DB, no cert.
- `bootstrapped`: has a bootstrap cert valid only for `/enroll` endpoint.
- `operational`: has an operational cert; full telemetry and command rights per policy.
- `quarantined`: connection rejected at policy layer; cert not yet revoked. Fast kill switch.
- `retired`: end-of-life; cert revoked, retained for audit.

**Enrollment endpoint:**

- `POST /enroll` — accepts CSR + enrollment token + bootstrap cert. Validates, issues operational cert via `ash_pki`, transitions device to `operational`, returns operational cert chain.
- Idempotent on token; replay protected.

**Multi-tenancy:**

- Tenant is threaded through every resource as a relationship and a policy filter.
- Cert SAN/CN conventions encode tenant, e.g. `URI:device://tenant-acme/devices/SN12345`.
- Policy primitives: `relates_to_tenant_via/1`, `actor_attribute_matches_tenant/1` for use in resource policies.

**Non-goals for v1:** device groups beyond tenant (covered by Segments), device-to-device relationships, fleet-wide actions (these belong in Segments + per-device commands).

### 5.3 `ash_mqtt`

Two distinct layers. Build them in this order; second depends on first.

#### Layer A: Resource extension and broker config generation

The `mqtt` DSL extension on a resource declares topic patterns, QoS, retain, payload schema, and ACL policy.

```elixir
defmodule MyApp.Device.Shadow do
  use Ash.Resource, extensions: [AshMqtt.Resource]

  mqtt do
    topic "tenants/:tenant_id/devices/:device_id/shadow/desired", as: :desired
    topic "tenants/:tenant_id/devices/:device_id/shadow/reported", as: :reported, direction: :inbound
    qos 1
    retain true
    payload_format :json  # or :cbor, :arrow_ipc, :protobuf, :opaque
    acl :tenant_isolated
  end
end
```

**Compile target:** EMQX rule definitions (pushed via REST API at deploy or boot) and Mosquitto ACL files (rendered to disk).

**ACL generation:** Resource policies → topic ACLs. A policy that filters by tenant becomes a topic-level ACL keyed on the cert's tenant SAN.

**Schema validation:** For `:json`, `:cbor`, `:protobuf` payloads the broker rule engine can validate via schema registry. For `:arrow_ipc` and `:opaque`, validation is deferred to whoever consumes the topic (typically the ingest endpoint, not via this library).

#### Layer B: Action invocation over MQTT

Ash actions exposed at topics, with request/response semantics built on MQTT 5 features (response topics, correlation data, content type).

```elixir
mqtt do
  action :reboot, topic: "tenants/:tenant_id/devices/:device_id/cmd/reboot"
  action :read_config, topic: "tenants/:tenant_id/devices/:device_id/cmd/read_config", reply: true
end
```

- Bidirectional: backend invokes device action; device invokes backend action.
- Correlation data is mandatory for `reply: true` actions; library generates response topic per request.
- Timeouts and retries are explicit per action.

**Device shadow as first-class:**

- `mqtt_shadow` DSL extension on a resource declares desired/reported attribute split.
- Generates the four standard topics (desired, reported, delta, get) with conventional shapes.
- AWS IoT and Azure IoT both use this pattern; we follow convention so devices and existing tooling can interop.

**Non-goals for v1:** sticky session management beyond MQTT 5 defaults, custom QoS upgrade/downgrade flows, topic aliases optimization.

### 5.4 `soot_telemetry`

**Resources:**

- `Telemetry.Schema` — versioned Arrow schema. Attributes: name, version, fingerprint (computed), arrow_schema_descriptor, status (active/deprecated). Schemas are immutable once active; new versions create new rows.
- `Telemetry.Stream` — declares a logical telemetry stream. Attributes: name, tenant_scope, current_schema_id, clickhouse_table, retention, partitioning, ingest_topic_or_endpoint.
- `Telemetry.IngestSession` — open ingest connections (for observability and rate limiting). Attributes: device_id, stream_id, opened_at, last_batch_at, batch_count, byte_count, sequence_high_water.

**Arrow schema declaration** (Ash attributes compile to Arrow schema):

```elixir
telemetry_stream do
  name :vibration
  fields do
    field :ts, :timestamp_us, required: true       # device-reported time
    field :ingest_ts, :timestamp_us, server_set: true  # server-ingest time
    field :device_id, :string, dictionary: true
    field :tenant_id, :string, dictionary: true, server_set: true
    field :axis_x, :float32
    field :axis_y, :float32
    field :axis_z, :float32
    field :sequence, :uint64, monotonic: true
  end
  retention months: 12
  clickhouse do
    engine "MergeTree"
    order_by [:tenant_id, :device_id, :ts]
    partition_by "toYYYYMM(ts)"
  end
end
```

**Ingest endpoint (`/ingest/:stream_name`):**

- Bandit/Plug, HTTP/2, mTLS-terminated by `AshPki.Plug.MTLS`.
- Long-lived connection; many Arrow IPC batches per connection.
- Batch metadata in HTTP headers or trailing metadata frame: `x-stream`, `x-schema-fingerprint`, `x-sequence-start`, `x-sequence-end`.
- Per-device policy resolved on connection open (cached, refreshed on Ash change events).
- Schema fingerprint validated against `Telemetry.Schema.active_for(stream)`. Mismatch → reject batch with structured error including current expected fingerprint and a hint URL where the device can fetch the new schema descriptor.
- Sequence number tracked per (device, stream); regression beyond a small window logged and rejected.
- Server-set fields (`ingest_ts`, `tenant_id`) are projected onto the Arrow batch in-memory before insert.
- Bulk insert via `ch` driver (native protocol).

**Rate limits:**

- Token bucket per (device, stream) and per (tenant, stream).
- Reject with `429` + `Retry-After` and a structured body.

**Authorization (default policies, overridable):**

- Device's tenant must match stream tenant scope.
- Device must be in `operational` state.
- Device must not be quarantined.
- Stream must not be paused or retired.

**ClickHouse migration generator:**

- `mix soot.telemetry.gen_migrations` — generates ClickHouse DDL from current `Telemetry.Stream` definitions.
- `mix soot.telemetry.migrate` — applies migrations.
- Schema evolution: additive changes (new nullable columns) generate `ALTER TABLE` migrations. Breaking changes require a new schema version and a documented backfill path.

**Non-goals for v1:** automatic backfill on schema change, multi-region replication coordination, tiered storage / cold storage automation.

### 5.5 `soot_segments`

**Resources:**

- `Segment` — a named slice of the fleet × metrics × time. Attributes: name, filter (Ash filter expression over Devices, evaluated at compile time to a SQL predicate), source_stream, metrics (list of metric specs: column, aggregation, alias), granularity (1m/5m/1h/1d), retention, version, status, materialized_target.
- `SegmentVersion` — historical versions for reproducibility. New segment definition = new version row; old version's MV remains until explicitly retired.

**Compilation target:** ClickHouse materialized views (preferred) or projections. Choice depends on segment shape; framework picks reasonable default per granularity.

**Migration semantics:**

- Changing a segment definition does **not** silently invalidate historical data.
- New version creates a new MV with a date floor (no backfill by default).
- Old MV is marked deprecated; operator decides retention.
- Backfill is an explicit action: `Segment.backfill(version_id, from: ~D[2024-01-01])`.

**Mix tasks:**

- `mix soot.segments.gen_migrations` — diff active segments vs. ClickHouse state, generate DDL.
- `mix soot.segments.migrate` — apply.

**Query helpers:**

- `Segment.query(name, range, dims)` — typed query builder against the MV, returning Ash-style results.
- Cinder-friendly: `Segment.cinder_query(name, range)` returns a query usable directly in Cinder tables.

**Non-goals for v1:** cross-segment joins, ad-hoc segment creation via UI, segment definitions over non-telemetry resources.

### 5.6 `soot_contracts`

The bridge between backend and device. **Read-only** from the device's perspective; the backend is the authority.

**Generates a contract bundle** (versioned, signed, served at a well-known endpoint):

- `manifest.json` — bundle version, generated_at, bundle fingerprint, signature.
- `topics.json` — MQTT topic patterns from `ash_mqtt`, with payload format references and ACL hints.
- `commands.json` — actions exposed over MQTT (request/response shapes, timeouts).
- `shadow.json` — desired/reported attribute schema for the Device shadow.
- `streams/{name}.arrow_schema` — Arrow schema files for each Telemetry.Stream.
- `streams/{name}.json` — stream metadata (endpoint, sequence requirements, batch size hints).
- `pki/trust_chain.pem` — current CA chain devices should trust.
- `pki/crl_url` — where to fetch the CRL.

**Endpoints (served by the Ash app):**

- `GET /.well-known/soot/contract` — current bundle manifest.
- `GET /.well-known/soot/contract/:fingerprint/...` — bundle assets.
- mTLS-protected; devices fetch with their operational cert.

**Mix tasks:**

- `mix soot.contracts.build` — assemble bundle from current resource definitions, sign with PKI key, serve.
- `mix soot.contracts.diff` — show diff between two bundle versions (for change review).

**Why this is the right shape:**

- Devices using `soot_device` (future high-level package) consume the bundle to generate local Ash resources for shadow, local Telemetry.Stream definitions for Dux upload, and command handlers.
- Devices using lower-level Elixir/Nerves code consume the same bundle to configure their own MQTT subscriptions and Dux schemas.
- Devices using non-Elixir runtimes (C, Rust, embedded) consume the JSON manifests directly.
- The backend never special-cases the device implementation. One contract, many runtimes.

**Non-goals for v1:** automatic device library code generation, schema migration negotiation (devices either match or fetch the new bundle).

### 5.7 `soot_admin`

Cinder-based building blocks for the operator's Phoenix LiveView admin app.

**Components:**

- `SootAdmin.DeviceTable` — Cinder table over Device, with status, last_seen_at, batch, certificate status. Filters and search out of the box.
- `SootAdmin.EnrollmentQueue` — devices in `unprovisioned`/`bootstrapped` states, with bulk actions.
- `SootAdmin.CertificateTable` — issued certs with status, expiry, revocation.
- `SootAdmin.TelemetryStreamPanel` — list streams, schema versions, ingest stats from `Telemetry.IngestSession`.
- `SootAdmin.SegmentTable` — segments with versions, status, last MV refresh.
- `SootAdmin.SegmentChart` — chart component over Segment data, suitable for dashboards.

**What this does NOT do:**

- Does not provide a finished admin app. Operator mounts these in their own LiveView routes.
- Does not handle authentication. Operator wires their own `ash_authentication` setup as the admin actor.
- Does not own routing or layout. Composable, not opinionated about app structure.

**Non-goals for v1:** real-time fleet maps, customizable dashboards beyond the provided panels, device console / SSH-like terminal.

### 5.8 `soot` (umbrella / meta-package)

- Pulls in all of the above with sensible defaults.
- Mix tasks:
  - `mix soot.new` — generate a fresh project with the framework wired up.
  - `mix soot.broker.gen_config` — render EMQX or Mosquitto config from current resources.
  - `mix soot.demo` — spin up a demo with a couple of simulated devices for local development.
- Documentation:
  - Quickstart from clean repo to working mTLS + telemetry in <30 minutes.
  - Honest scaling cliff doc: "this topology serves N devices / M msg/sec; here's what to change at each ceiling."
  - Device-side integration guide (forward-looking, points at the contracts bundle).
  - Migration paths for breaking changes.

## 6. Device-Side (Forward-Looking)

Not built in the initial phases. Architecture sketched here so backend decisions don't paint device-side into a corner.

### The imperative layer is the implementation; the declarative layer orchestrates it

The device-side stack is a single runtime with two ways to configure it.

The **imperative layer** (`soot_device_protocol`, future) contains the actual working code: an MQTT client wrapper that handles enrollment and reconnect, a shadow sync engine, a command dispatcher with correlation handling, a Dux-backed telemetry pipeline (local DuckDB buffer plus upload over HTTP/2 ingest or ADBC), a contract bundle fetcher and reconciler. It exposes Elixir behaviors so each piece is replaceable, and it ships working default implementations of all of them. A developer using this layer writes plain Elixir/Nerves code that calls into these components, configures them with their device's specifics, and implements callbacks for application logic.

The **declarative layer** (`soot_device`, future) is a thin DSL surface that takes resource-style declarations and wires up the imperative components from them. It contains very little runtime code of its own — mostly compile-time generation that produces the same configuration and callback wiring the imperative user would have written by hand. A developer using this layer writes Ash DSLs; the library expands them into calls into the imperative layer.

Both surfaces run **the same code paths on the device**. The DSL user simply didn't have to type as much. The imperative user has more flexibility to interpose custom behavior, swap component implementations, or handle edge cases the DSL doesn't anticipate. Neither user is "going around" the other; they're using the same machine through different interfaces.

This shape has consequences:

- The substantive engineering effort is in the imperative layer. The declarative layer, when it comes, is mostly DSL design and code generation.
- Mixing surfaces within a single device is fine and expected. A developer can declare 90% of their device with the DSL and drop into imperative calls for the 10% that needs custom handling.
- The protocol contract is enforced by the imperative layer's implementations, not by either surface independently. There is no way to use the framework and accidentally violate the protocol, because the only code that talks to the broker, the ingest endpoint, and the contract bundle is in the imperative layer.

### The protocol contract (enforced by the imperative layer)

The five behaviors any participating device honors:

1. **Identity:** operate with an mTLS cert from the framework's PKI. Honor enrollment flow on first boot.
2. **Shadow:** subscribe to desired topic, publish to reported topic, reconcile on delta. Persistence of last-known shadow recommended but not required.
3. **Commands:** subscribe to command topics, dispatch to handlers, publish responses with correlation IDs and content type.
4. **Telemetry:** produce Arrow batches conforming to the active schema, include monotonic sequence numbers per stream, deliver via the ingest endpoint (default) or via Dux's ADBC path (when devices have direct ClickHouse identity, which is rare). Buffer locally during connectivity loss.
5. **Contract refresh:** poll or subscribe for contract bundle changes, reconfigure on bundle version change. Handle schema-mismatch rejections from the ingest endpoint by fetching the new bundle.

The imperative layer ships working implementations of all five, exposed as behaviors so they can be replaced piecewise. The declarative layer wires them up from DSL declarations. A non-Elixir device implementation (C, Rust, embedded) consumes the contract bundle directly and implements these behaviors in its own runtime; it cannot use the imperative layer but it must honor the same five behaviors at the wire level.

### Why Dux fits naturally

- Speaks Arrow natively (DuckDB internals), so the device's local storage format is the wire format — no marshaling overhead.
- ADBC ClickHouse driver gives a wire-compatible upload path: the same Arrow batches that populate the local DuckDB can be uploaded as ADBC batches to ClickHouse, *or* sent over the Ash app's HTTP/2 ingest endpoint with mTLS. Default is the ingest endpoint; ADBC-direct is an option for deployments that grant devices direct ClickHouse identity.
- Local query capability (DuckDB) means devices can do edge-side aggregation before upload, reducing bandwidth. This is a feature of the Dux integration regardless of which surface configured it.

The Dux-backed telemetry pipeline is one of the imperative layer's components. The declarative layer's telemetry DSL configures it; an imperative user calls it directly with their own scheduling and source logic.

### Why we don't share resource code between backend and device

The backend `Device` is a row in Postgres with policies, multi-tenancy, and certificate relationships. The device's self-knowledge is "my serial, my cert, my current shadow." These look similar but have different lifecycles, different validation rules, and different access patterns. Sharing resource code creates coupling that hurts both sides.

What is shared is the **protocol and payload contract**, expressed as the contract bundle. The declarative surface generates local resources from the bundle; the imperative surface consumes the bundle directly through the contract refresh component. Neither imports backend resource code.

If we ever find we genuinely want to share resource code (after the device-side packages exist and we've felt the pain), we can extract. Premature sharing locks in the wrong abstraction.

## 7. Build Phases

Each phase produces a working demo. Phases are sized to fit a single Claude Code instance unless noted.

### Phase 1 — `ash_pki` foundation

**Scope:**
- Resources: CertificateAuthority, Certificate, RevocationList.
- Software key strategy fully implemented.
- Strategy interface designed for `:pkcs11`, `:kms`, `:imported` (no implementations, just the behavior).
- Actions: issue, revoke, publish_crl, import_certificate (basic).
- `mix ash_pki.init` task.
- `AshPki.Plug.MTLS` for Bandit, with verify-fun integration.

**Demo target:** `mix ash_pki.init` from clean repo → working CA → issue a client cert → start a small Bandit endpoint that requires mTLS → connect with the issued cert → see the cert exposed as actor in an Ash policy.

**Non-goals:** HSM/PKCS#11, KMS, cross-CA federation, ACME, OCSP responder. Pre-provisioned import is stubbed at the action level but not exercised end-to-end.

**Owner:** Single instance. Blocks everything else.

### Phase 2 — `soot_core`

**Scope:**
- Resources: Tenant, SerialScheme, ProductionBatch, Device, EnrollmentToken.
- Device state machine with `AshStateMachine`.
- CSV import for ProductionBatch.
- `/enroll` endpoint.
- Multi-tenancy primitives (policy helpers, SAN/CN conventions).
- Shadow modeled as a related resource (not the MQTT shadow yet — that's Phase 3 — but the backend representation).

**Demo target:** create a tenant → define a serial scheme → import a batch CSV → simulate a device hitting `/enroll` with a bootstrap cert → see it transition to operational → query its shadow via Ash.

**Non-goals:** MQTT integration (Phase 3), telemetry (Phase 4), admin UI.

**Owner:** Single instance. Depends on Phase 1.

### Phase 3 — `ash_mqtt`

**Scope:**
- **Sub-phase 3a:** Resource extension and broker config generation. EMQX rule push via REST API; Mosquitto ACL file rendering. Schema validation hooks.
- **Sub-phase 3b:** Action invocation over MQTT (request/response with correlation). Shadow DSL with the four standard topics.

**Demo target:** declare a `Device.send_command` action exposed over MQTT → publish a command from a test client → see it execute through Ash with proper authorization based on publisher's cert → see shadow desired/reported reconciliation work end-to-end.

**Non-goals:** topic aliases, custom QoS flows, per-tenant broker isolation.

**Owner:** Can split between two instances (3a and 3b) sharing the `ash_mqtt` namespace; coordinate daily on the resource DSL. Depends on Phases 1 and 2.

### Phase 4 — `soot_telemetry`

**Scope:**
- Resources: Telemetry.Schema, Telemetry.Stream, Telemetry.IngestSession.
- Arrow schema DSL compiling to actual Arrow schema.
- `/ingest/:stream_name` HTTP/2 endpoint, mTLS, Arrow IPC batches.
- ClickHouse DDL generator and migration tasks.
- Schema fingerprinting and version tracking.
- Sequence number replay protection.
- Per-device and per-tenant rate limits.
- Default authorization policies.

**Demo target:** declare a telemetry stream → run migration to create ClickHouse table → push Arrow batches from a test client over mTLS → query data in ClickHouse → trigger schema-mismatch rejection → see the rate limiter cut a misbehaving simulated device off cleanly.

**Non-goals:** segments (Phase 5), separate ingest service, automatic backfill, multi-region replication.

**Owner:** Single instance, but a meaty one. Depends on Phases 1 and 2. Can run in parallel with Phase 3 after Phase 2 lands (MQTT and Arrow ingest don't share much code, only the policy layer from `soot_core`).

### Phase 5 — `soot_segments`

**Scope:**
- Resources: Segment, SegmentVersion.
- Compilation to ClickHouse MVs / projections.
- Versioning and migration semantics with explicit (non-automatic) backfill.
- Query helpers including Cinder-friendly form.
- Mix tasks for migration generation and application.

**Demo target:** define a segment ("temperature sensors in tenant X, hourly p95") → see MV created → push telemetry → query the rollup → modify the segment definition → see new version created with date floor → run explicit backfill → see data populate.

**Non-goals:** cross-segment joins, ad-hoc segment UI.

**Owner:** Single instance. Depends on Phase 4.

### Phase 6 — Polish, contracts, admin, umbrella

**Scope:**
- `soot_contracts` — bundle generator, signed manifest, well-known endpoints, diff tooling.
- `soot_admin` — Cinder components for all resources; LiveView panels.
- `soot` — umbrella package, broker config templates, `mix soot.new` generator, demo app, scaling cliff documentation.
- HSM/PKCS#11 strategy in `ash_pki` (separate skill area, separate instance).
- Pre-provisioned cert import end-to-end in `ash_pki`.
- Verified-header plug variant for cloud LB termination.
- JWT-based identity escape hatch (alternative to mTLS) for environments without mTLS support.

**Demo target:** `mix soot.new` → working project → operator plugs Cinder admin components into their LiveView app → admin can browse fleet, enroll devices, see telemetry stats, define segments → contract bundle served at well-known endpoint and consumable by a hand-written test device script.

**Owner:** Multiple instances in parallel — umbrella/admin/contracts can be one stream, HSM/import work is a separate skill area for a different instance.

## 8. Cross-Cutting Concerns

### Observability

- All ingest/auth/policy decisions emit `:telemetry` events with structured metadata.
- `IngestSession` and analogous resources give a queryable record of what's been happening in OLTP, alongside the OLAP telemetry data.
- Standard `:telemetry` handlers ship with the umbrella for OpenTelemetry integration; opt-in.

### Audit

- Cert issuance, revocation, enrollment, quarantine actions all generate audit log entries via `ash_paper_trail` (recommended, opt-in).
- Contract bundle versions are signed and retained; operator can prove what contract was active at any past time.

### Testing infrastructure

- Each library ships test helpers for simulating devices: ephemeral CA, in-memory broker shim (or testcontainers), Arrow batch generators.
- Demo simulators in the umbrella for local-development volume testing.

## 9. Open Questions (Defer)

These are explicitly *not* decided and should not block phase work. Revisit after Phase 4 lands.

- **CBOR vs JSON for MQTT control payloads.** Defaulting to JSON for now; CBOR support is a payload_format option but not the default.
- **Shadow conflict resolution semantics** beyond simple last-write-wins per attribute. AWS and Azure both have nuanced rules; we may not need to match either.
- **OTA integration** — assumed NervesHub. Sketch in a follow-up spec; out of scope here.
- **Edge gateway pattern** — devices behind a gateway that aggregates and forwards. The contract model should accommodate this; defer concrete design.
- **Time sync** — devices with bad clocks. Dual timestamps (device-reported + server-ingest) are baked in; handling extreme skew is a future concern.

## 10. Handoff Notes for Phase Implementers

- **Read this entire spec before starting your phase.** The boundary decisions matter; don't redesign them inside your phase.
- **Each phase has a one-page scope/non-goals doc derived from sections 5 and 7.** Stick to it. If you find a non-goal becomes a blocker, raise it; do not silently in-scope it.
- **Multi-tenancy is in scope from Phase 2 onward, always.** Don't ship anything that bakes in single-tenant assumptions.
- **The contracts bundle is the device interface.** When in doubt about what to expose to devices, the answer is "put it in the bundle." When in doubt about how, the answer is "JSON manifest plus binary asset files."
- **mTLS is the default; document it as such.** Other auth modes are escape hatches in Phase 6.
- **Ash extensions and generators are the implementation pattern.** If you find yourself writing a runtime that bypasses Ash, stop and reconsider.
- **Test against EMQX *and* Mosquitto in CI.** The lean-default promise depends on Mosquitto working.
- **Document the scaling cliff as you build.** Each phase's docs should include "this works up to roughly X; beyond X here's what changes."
