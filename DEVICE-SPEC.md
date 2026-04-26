# Soot — Device-Side Libraries

**Status:** Draft v1
**Audience:** Device library implementers (Elixir / Nerves)
**Companion:** `SPEC.md` (backend v0.1, shipped) and `SPEC-2.md`
(backend v0.2, planned). The device side consumes the contract bundle
that `soot_contracts` already produces; nothing in this spec requires
additional backend surface.

## 1. Purpose

The framework's device side: the Elixir/Nerves code that runs on a
device and honors the protocol contract published by the backend. The
goals are the same as the backend's:

1. **Lean by default.** A device needing only telemetry + shadow runs
   on a small Nerves target with one MQTT connection and one HTTP/2
   long-lived ingest connection.
2. **The contract bundle is the source of truth.** Nothing in the
   device library hardcodes topic shapes, schema descriptors, or
   trust material; everything flows from a fetched and verified
   bundle.
3. **The imperative layer is the implementation.** A DSL surface
   exists (§5.2) but it expands into calls into the imperative layer;
   neither is a "lower-level alternative" to the other.
4. **Non-Elixir runtimes consume the same contract.** A C / Rust /
   embedded runtime that honors the same five behaviors (§3) is a
   first-class citizen; the Elixir libraries are a particularly
   convenient implementation, not the only legitimate one.

This spec covers the Elixir / Nerves implementation in detail.
Non-Elixir runtimes are sketched at the protocol level only.

## 2. Principles

1. **Match the backend's contract exactly.** Topic patterns, payload
   formats, sequence semantics, fingerprint negotiation: byte-for-byte
   identical to what the backend declared. Discrepancies are bugs in
   this library, never in the contract.
2. **One process per concern.** MQTT client, shadow sync, command
   dispatcher, telemetry pipeline, and contract refresh are separate
   supervised processes. They communicate through documented APIs,
   not shared state.
3. **Fail loudly on protocol mismatch.** A device that gets a 409
   fingerprint-mismatch from `/ingest` *fetches the new bundle*; it
   does not silently retry against the old fingerprint.
4. **Local-first telemetry.** Network outages are the rule, not the
   exception. The telemetry pipeline buffers locally (Dux) and
   uploads when a path is available; loss is a conscious operator
   choice (configurable retention), never a bug.
5. **No backend RPC for runtime decisions.** The device decides what
   to publish, when to reconnect, what to retain locally. The
   backend provides the contract; the device runs against it.
6. **Declarative is sugar.** Anything the DSL does, the operator can
   do by hand against the imperative API and get the same behavior.

## 3. The protocol contract — five behaviors

Repeated from `SPEC.md` §6 for the device-side audience:

1. **Identity.** Operate with an mTLS cert from the framework's PKI.
   Honor enrollment flow on first boot.
2. **Shadow.** Subscribe to desired topic, publish to reported topic,
   reconcile on delta. Persistence of last-known shadow recommended
   but not required.
3. **Commands.** Subscribe to command topics, dispatch to handlers,
   publish responses with correlation IDs and content type.
4. **Telemetry.** Produce Arrow batches conforming to the active
   schema, include monotonic sequence numbers per stream, deliver via
   the ingest endpoint (default) or via Dux's ADBC path (when devices
   have direct ClickHouse identity, which is rare). Buffer locally
   during connectivity loss.
5. **Contract refresh.** Poll or subscribe for contract bundle
   changes, reconfigure on bundle version change. Handle
   schema-mismatch rejections from the ingest endpoint by fetching
   the new bundle.

A non-Elixir device implementation that honors these five behaviors
at the wire level is a first-class participant. The libraries below
implement them in Elixir / Nerves; replication in another language is
expected and supported.

## 4. Library map

| Library                       | Role                                                                   |
|-------------------------------|------------------------------------------------------------------------|
| `soot_device_protocol`        | Imperative implementation of the five behaviors. Ships as a set of supervised GenServers with documented APIs and replaceable behaviors. |
| `soot_device`                 | Declarative DSL on top of `soot_device_protocol`. Compile-time generation that wires the imperative components from a `device do …` block. |
| `soot_device_test`            | Test fixtures and simulators: an in-memory broker shim, an in-memory ingest endpoint, fake contract bundle producer. |

Boundary rules (mirroring `SPEC.md` §4):

* `soot_device_protocol` and `soot_device` ship as separate hex
  packages so the imperative layer is usable without pulling in the
  DSL framework.
* `soot_device_test` is a test-only dep.
* No device library depends on a backend library at runtime. The
  device fetches the contract bundle over HTTPS; it does not import
  `soot_core` / `soot_telemetry` / etc.
* Cert / topic / schema knowledge flows entirely through the contract
  bundle — never through hardcoded constants.

## 5. `soot_device_protocol` — imperative layer

This is the substantive engineering effort. The DSL is sugar; this is
the code.

### 5.1 Components

Each component is a GenServer (or supervisor of GenServers). All are
replaceable through behaviors so an operator can swap a default
implementation for one that fits a constrained target (e.g. a static
shadow for a sensor that has no settable state).

#### `SootDeviceProtocol.MQTT.Client`

Wrapper around an MQTT 5 client (initial pick: `:emqtt`, the same
client `ash_mqtt`'s runtime uses on the backend; alternative pick:
`tortoise_mqtt` if `:emqtt`'s C-NIF dependency is a problem on a
target). Connects with mTLS using the operational cert + key from
the device's identity store.

API:

* `connect/2`, `disconnect/1`
* `publish/4` — topic, payload, qos, properties
* `subscribe/3` — filter, qos, handler MFA / function

Handles MQTT 5 properties on inbound messages (response_topic,
correlation_data, content_type) and surfaces them to the caller.

#### `SootDeviceProtocol.Shadow.Sync`

Reconciles desired and reported state for the device's shadow. On
boot:

1. Subscribes to `<base>/desired` and `<base>/delta`.
2. Reads persisted shadow from local storage (a file under
   `:persistence_dir`).
3. Publishes `<base>/reported` with the persisted state.

On `<base>/desired` updates:

* Diffs against current reported state.
* Calls each registered handler for changed top-level keys.
* On handler success, updates persisted state and publishes
  `<base>/reported`.
* On handler error, leaves reported as-is and logs.

On `<base>/delta` (server's view of difference):

* Same as `<base>/desired` but for keys the server explicitly flagged.

API:

* `start_link/1` with `:base_topic`, `:storage`, `:handlers` (a
  `%{key => handler_fun}` map).
* `report/2` — push a reported-state update for `key`. Used by code
  outside the desired-state flow (e.g. uptime counter).
* `current/1` — read the device's current view of reported state.

#### `SootDeviceProtocol.Commands.Dispatcher`

Subscribes to `<command_topic>` patterns from the contract's
`commands.json`. On inbound:

* Validates payload against `payload_format` declared in the bundle.
* Calls the registered handler for that command.
* Publishes a reply if the request had `response_topic` and
  `correlation_data`.

API:

* `start_link/1` with `:commands` (a `%{name => handler_fun}` map).
* `register/3` — add a command at runtime.

Operator-supplied handlers are pure functions of `(payload, meta) ->
{:reply, body} | :ok | {:error, reason}`. The dispatcher takes care
of correlation and reply-topic publication.

#### `SootDeviceProtocol.Telemetry.Pipeline`

Local Dux-backed (DuckDB) buffer plus an uploader. Writes go through
this; the uploader either:

* **Default path:** posts Arrow IPC batches to `/ingest/<stream>` on
  the backend, mTLS-authenticated, with the headers the backend's
  `Plug.Ingest` requires (`x-stream`, `x-schema-fingerprint`,
  `x-sequence-start`, `x-sequence-end`).
* **ADBC-direct path:** writes directly to ClickHouse over ADBC. Only
  meaningful when the device has direct ClickHouse identity, which
  is rare; default off.

Buffer semantics:

* Bounded by `:retention_bytes` (default ~64 MiB) and
  `:retention_rows` (default ~1 M); whichever fires first triggers
  drop-oldest.
* Each row is keyed by stream + monotonic sequence number per
  stream. The sequence number is generated locally and persisted
  across reboots.
* Upload retries with capped exponential backoff; transient HTTP
  errors keep the row, permanent errors (409 fingerprint mismatch,
  410 stream retired) drop the row and trigger a contract refresh.

API:

* `write/3` — stream name, row, opts.
* `flush/1` — force an upload attempt.
* `stats/1` — row count, byte count, oldest-row age.

#### `SootDeviceProtocol.Contract.Refresh`

Periodically (default every 5 min, configurable) GETs
`/.well-known/soot/contract`; if the manifest's fingerprint differs
from the locally-cached one, fetches the asset paths it cares about
and verifies the manifest signature against the trust chain it
already has. On success:

* Reconfigures the MQTT client's subscriptions per the new
  `topics.json`.
* Reconfigures the telemetry pipeline's known schemas per the new
  `streams/*.json`.
* Persists the new bundle locally.

On failure (network, signature mismatch): retries with backoff;
keeps using the previous bundle until refresh succeeds.

API:

* `start_link/1` with `:url`, `:trust_pems`, `:storage`,
  `:on_change` callback.
* `force_refresh/0` — used by the telemetry pipeline when it gets a
  fingerprint-mismatch rejection.

#### `SootDeviceProtocol.Enrollment`

Bootstrap: on first boot, the device has a bootstrap cert (burned
in at manufacturing time, or shipped via the operator's
provisioning channel). It generates a fresh keypair and submits a
CSR to `POST /enroll` along with the bootstrap-cert-authenticated
mTLS connection. Receives the operational cert chain, persists it,
and switches subsequent connections to the new identity.

API:

* `start_link/1` with `:bootstrap_cert`, `:bootstrap_key`,
  `:enroll_url`, `:storage`.
* `enrolled?/0` — boolean; used by the supervisor to decide whether
  to start the operational stack.

### 5.2 Storage abstraction

A small `SootDeviceProtocol.Storage` behavior with an
`Local` (file-system, default for Nerves) and an `Ets` (in-memory,
default for the host VM) implementation. Components that persist
across reboots take a storage handle in their start_link opts.

### 5.3 Supervision tree

```
SootDeviceProtocol.Supervisor (:rest_for_one)
├─ Storage.Local
├─ Enrollment   (if not enrolled, blocks the rest)
├─ MQTT.Client
├─ Contract.Refresh
├─ Shadow.Sync
├─ Commands.Dispatcher
└─ Telemetry.Pipeline
```

`:rest_for_one` so a transport layer crash takes the dependent
processes down with it; the storage and enrollment layers are
independent.

### 5.4 Non-goals for v1

Carried over from `SPEC.md` §6:

* No shared resource code with the backend. The backend `Device` and
  the device's self-knowledge have different lifecycles, validation
  rules, and access patterns.
* No higher-level "fleet behaviors" library on the device side. Each
  device knows itself; cross-device coordination is the backend's
  job.
* No device-side admin / debugging UI. Devices don't ship a
  webserver; they emit logs and shadow updates.

## 6. `soot_device` — declarative layer

A Spark DSL on top of `soot_device_protocol`. The DSL contains very
little runtime code of its own — mostly compile-time generation that
produces the same configuration and callback wiring an imperative user
would have written by hand.

### 6.1 DSL surface

```elixir
defmodule MyDevice do
  use SootDevice,
    contract_url: "https://soot.example.com/.well-known/soot/contract",
    serial: "ACME-EU-WIDGET-0001-000001"

  identity do
    bootstrap_cert_path "/data/pki/bootstrap.pem"
    bootstrap_key_path  "/data/pki/bootstrap.key"
    operational_storage :file_system
  end

  shadow do
    on_change :led, &handle_led/2
    on_change :sample_rate, &handle_sample_rate/2

    report :uptime_s, every: :minute, value: &uptime/0
    report :firmware_version, value: "0.4.2"
  end

  commands do
    handle :reboot, &handle_reboot/2
    handle :read_config, &handle_read_config/2
  end

  telemetry do
    stream :vibration do
      sample interval: 100, source: &read_vibration/0
      sequence_persist :file_system
    end
  end
end
```

### 6.2 Compile-time generation

`use SootDevice` expands into a supervisor with the
`SootDeviceProtocol.*` components configured from the DSL. The
generated supervisor calls into the imperative layer; nothing magical
happens at runtime that an imperative user couldn't replicate by hand.

### 6.3 Mixing surfaces

A `soot_device`-using module can drop into raw imperative calls for a
component the DSL doesn't anticipate (e.g. a custom
`SootDeviceProtocol.Telemetry.Pipeline` that compresses payloads
before upload). Both surfaces operate on the same imperative
implementation; there is no "around" path.

## 7. `soot_device_test` — fixtures and simulators

Used by the device libraries' own test suites and by operators
testing their device firmware against a synthetic backend.

### 7.1 In-memory broker shim

A small MQTT-5-shaped server that records publishes, lets tests
inject inbound messages, and supports the property fields
(`response_topic`, `correlation_data`, `content_type`) the runtime
relies on. Mirrors the `AshMqtt.Runtime.Transport.Test` pattern from
the backend.

### 7.2 In-memory ingest endpoint

A `Plug` that pretends to be `SootTelemetry.Plug.Ingest`: validates
headers, accepts the body, exposes "what was uploaded" assertions to
tests.

### 7.3 Fake contract bundle producer

A function that takes a list of MQTT topic descriptors and stream
schemas and produces a signed bundle structurally identical to one
`soot_contracts` would emit — without needing a running backend.

## 8. Build phases

Each phase produces a working device library that an operator can
flash to a Nerves target and exercise against the backend stack
already running from `SPEC.md` v0.1.

### Phase D1 — `soot_device_protocol` skeleton + enrollment + contract refresh

* Storage abstraction.
* `Enrollment` against `/enroll`.
* `Contract.Refresh` against `/.well-known/soot/contract`.
* `MQTT.Client` connecting with the operational cert.
* Smoke test: a device boots, enrolls, fetches the bundle, and
  connects to the broker.

**Owner:** Single instance. No backend changes required.

### Phase D2 — Shadow sync + commands dispatcher

* `Shadow.Sync` with desired/reported reconciliation, persistent
  storage, handler dispatch.
* `Commands.Dispatcher` with payload validation against the
  bundle's `commands.json`, correlation handling, reply
  publication.
* Smoke test: backend pushes a desired-state update; device updates
  reported within a defined window.

**Owner:** Single instance. Depends on D1.

### Phase D3 — Telemetry pipeline

* Dux-backed local buffer.
* HTTP/2 ingest uploader against `/ingest/<stream>`.
* ADBC-direct uploader (deferred — ADBC ClickHouse driver maturity
  on Nerves targets is unproven; keep as a code path but don't
  default it on).
* Schema-fingerprint mismatch handling: trigger
  `Contract.Refresh.force_refresh/0` on 409.
* Sequence-number persistence across reboots.

**Owner:** Single instance. Depends on D1; can run in parallel with
D2.

### Phase D4 — `soot_device` declarative layer

* Spark DSL.
* Compile-time generation into a supervisor + configured imperative
  components.
* Documentation: how to mix DSL and imperative for a single device.

**Owner:** Single instance. Depends on D1 + D2 + D3.

### Phase D5 — Nerves integration + simulators + e2e tests

* `:soot_device_nerves` shim with sensible Nerves defaults
  (storage, time sync, system clock fallback).
* `soot_device_test` simulators.
* End-to-end test rig: Nerves QEMU + backend stack, exercises every
  protocol behavior.
* Documentation: device firmware quickstart from "I have a Nerves
  project" to "my device shows up in the admin UI".

**Owner:** Single instance. Depends on D1–D4.

## 9. Dependencies

A consolidated list of expected dependencies; pinning happens at
implementation time:

| dep                     | purpose                                            | choice signal |
|-------------------------|----------------------------------------------------|---------------|
| `:emqtt` or `tortoise_mqtt` | MQTT 5 client                                  | mirror the backend's pick once 3b stabilises |
| `:dux` (or DuckDB binding) | local Arrow-shaped buffer                       | per `SPEC.md` §6.5 — Dux fits naturally        |
| `:adbc` (optional)      | direct ClickHouse upload                            | only needed for the rare direct-identity path  |
| `:mint` / `:finch`      | HTTP/2 client for ingest + bundle fetch             | pick the one already on the Nerves target      |
| `:x509`                 | cert + CSR ops                                      | already used backend-side                       |

Nerves-target portability dictates avoiding heavyweight C-NIFs where
possible. The MQTT-client choice and Dux's NIF surface are the two
likely friction points.

## 10. Cross-cutting

### 10.1 Observability

The same `:telemetry` events backend-side: each component emits
events for connect/disconnect/publish/subscribe. Operators wire to
their preferred handler.

### 10.2 Audit

Devices don't ship audit logs to the backend on every action; they
emit shadow `reported` updates for state-changing events. The audit
trail lives in `ash_paper_trail` on the backend, populated from
shadow updates.

### 10.3 Testing strategy

* `soot_device_protocol` and `soot_device` unit tests run on the
  host VM with no Nerves target needed; the storage and broker
  layers swap to in-memory fixtures.
* `soot_device_nerves` integration tests run against a Nerves QEMU
  target.
* End-to-end tests in `soot_device_test` boot the backend stack
  (using the simulators from `SPEC.md` §8.3) plus a host-VM device
  and exercise the full protocol.

## 11. Open questions (defer)

Not decided; revisit after D3 lands.

* **Shadow conflict resolution.** v0.1 of the device side does the
  same last-write-wins as the backend's `SootCore.DeviceShadow`. If
  backend `SPEC-2.md` §5.5 lands first, the device side picks up the
  per-attribute strategy passively.
* **OTA on the device.** `SPEC-2.md` §5.3 covers backend OTA via
  NervesHub; the device side's NervesHub integration is well-trodden
  and stays out of this spec.
* **Edge gateway internals.** A gateway is a special-case
  `soot_device` deployment that forwards on behalf of inner devices.
  Details once the backend's edge-gateway pattern (`SPEC-2.md` §5.4)
  has shape.
* **Power-constrained scheduling.** Devices that wake briefly,
  upload, sleep. The protocol supports it (HTTP/2 connections
  closed cleanly between bursts; MQTT 5 sticky sessions); a Nerves
  helper for this pattern is a follow-up.

## 12. Handoff notes

* **Read this entire document plus `SPEC.md` §6 before starting your
  phase.** The architecture is in §6 of the original spec; this doc
  fleshes out the libraries, not the architecture.
* **Each phase has a one-page scope/non-goals derived from the
  matching section here.** Stick to it.
* **The protocol contract is the wire format of the bundle, not this
  spec.** When in doubt about what a behavior should do, refer to
  `soot_contracts`'s emitted bundle for the active backend.
* **Tests ship with features.** Same rule as backend.
* **No backend-resource imports on the device side, ever.** The
  bundle is the interface.
