# Soot — Scaling Cliff

The default Soot topology is one Elixir node, one MQTT broker
(Mosquitto or EMQX single-node), one Postgres for OLTP, one
ClickHouse for OLAP. This is intentional: a small operator should be
able to stand the system up with one app and four processes, and
nothing in the framework forecloses scaling out.

This document walks each layer's ceiling and the change that lifts it.
The numbers are envelopes, not guarantees: actual throughput depends
on payload size, schema width, broker tuning, and network
characteristics. Treat them as "you should plan for the next layer
before you hit this".

## Topology overview

```
                 ┌──────────────────────────────────────┐
                 │   Elixir app (Bandit + Ash + plugs)  │
                 └─┬────────────┬─────────────────┬─────┘
                   │            │                 │
                   │ MQTT       │ HTTP/2 ingest   │ TLS
                   ▼            ▼                 ▼
           ┌──────────────┐ ┌──────────┐  ┌──────────────┐
           │   Broker     │ │ ClickHouse│  │ Postgres /   │
           │ (Mosq/EMQX)  │ │ (OLAP)    │  │ ETS / SQLite │
           └──────────────┘ └──────────┘  └──────────────┘
                   ▲
                   │ mTLS
                   ▼
                ┌──────┐
                │ devs │
                └──────┘
```

## Layer 1 — Elixir app

### Single-node ceiling

* **Sustained ingest:** ~5–10k batches/sec per app node, depending on
  Arrow batch size. The `Plug.Ingest` happy path is well under 1ms;
  `IngestSession` ETS updates are the dominant cost.
* **Concurrent device connections:** ~50k MQTT + ingest sessions per
  node before file-descriptor and scheduler-saturation issues
  dominate.
* **Mix-tasks at boot:** `Registry.register_all/1` for telemetry +
  segments at boot is O(modules). 100s of streams is fine; 10k+ takes
  enough time to notice.

### When to scale out

When average CPU utilisation passes ~50% under peak load, OR when the
scheduler-utilisation telemetry from `:erlang.statistics/1` shows
sustained run-queue length above the number of cores.

### How

* **Horizontal Elixir nodes behind a TCP / HTTP/2 load balancer.** The
  ingest endpoint is stateless once the per-(device, stream)
  high-water row exists — any node can serve any device's batch as
  long as the OLTP store is shared.
* **Pull `Plug.Ingest` into a separate service.** The
  `SootTelemetry.Writer` behavior is the seam: a Rust/Go ingest
  service consumes the same contract bundle, validates fingerprint /
  sequence / rate limits the same way, and writes to ClickHouse
  directly. The Elixir app can step out of the telemetry hot path
  entirely.
* **Switch the rate limiter to a shared store.** The default
  `SootTelemetry.RateLimiter` is per-node ETS. For multi-node
  per-tenant rate limiting, plug in a Redis-backed implementation
  (the surface is `take/3` returning `{:ok | :rate_limited, …}`).

## Layer 2 — MQTT broker

### Single-broker ceiling

* **Mosquitto:** ~10k concurrent connections, single-digit-thousand
  messages/sec at QoS 1. CPU-bound past that.
* **EMQX (single node):** ~100k connections, low-six-digit msgs/sec.

### When to scale out

* Connection count approaches the single-node ceiling, or
* The broker's CPU runs hot during peak fan-out (many subscribers per
  topic), or
* You want zero-downtime broker upgrades.

### How

* **EMQX cluster.** The framework's `BrokerConfig.EMQX` already
  produces REST-API-shaped JSON; push to one node and EMQX replicates
  the rules to peers. ACLs scoped to `${username}` / `${clientid}`
  cluster-shard cleanly.
* **Don't cluster Mosquitto.** Mosquitto isn't built for it. The
  upgrade path is "switch to EMQX (or NATS, or VerneMQ) and re-render
  the ACLs".

## Layer 3 — OLTP (Postgres or SQLite)

### Single-node ceiling

* **Postgres:** the OLTP store backs `soot_core` (Tenant, Device,
  Batch, Cert) and the registry rows for telemetry / segments /
  contracts. The hot writes are device shadow updates,
  IngestSession row updates, and bundle publishes. Single-node
  Postgres on commodity hardware handles tens-of-thousands of writes
  per second easily.
* **SQLite (small deployments):** fine up to a few hundred devices
  with bursty traffic; reads scale fine, but the single-writer
  serialisation becomes a bottleneck under high write rates.

### When to scale out

* P99 write latency above ~50ms during peak, or
* Tenant count approaches the multi-tenant-pgbouncer fan-out limits
  (~hundreds of `SET` commands per sec per pgbouncer instance).

### How

* **Read replicas** for the admin UI / Cinder tables.
* **Per-tenant sharding** at the Ash domain level — `Tenant` already
  carries the slug; route OLTP writes to the per-tenant shard with
  `Ash.set_tenant/2`.
* **Move IngestSession out of OLTP.** It's the noisiest table. The
  high-water + counters can live in Redis or a dedicated KV store
  with periodic snapshots.

## Layer 4 — ClickHouse (OLAP)

### Single-node ceiling

* **Telemetry inserts:** millions of rows/sec on a moderate node, as
  long as inserts are batched (ingest plug already does this).
* **MV refreshes:** the `AggregatingMergeTree` MVs from `soot_segments`
  do per-insert merging; this is the OLAP hot path.

### When to scale out

* Disk-write throughput saturates on the inserts, or
* MV merge backlogs accumulate (visible via `system.merges`), or
* You need cross-region availability.

### How

* **ClickHouse cluster** with `ReplicatedMergeTree` and `Distributed`
  engines. The DDL emitted by `mix soot_telemetry.gen_migrations` and
  `mix soot_segments.gen_migrations` is a starting point — wrap with
  the cluster-aware engines manually.
* **Tiered storage** for long-tail segments. Configure ClickHouse's
  storage policies; `soot_segments` versioning means old MV tables
  can move to cold storage independently.
* **Add Kafka/Redpanda in front of ClickHouse** for replay + stream
  processing. The `SootTelemetry.Writer` behavior is the swap-in
  point.

## Layer 5 — PKI

### Single-CA ceiling

* `ash_pki` issues certs on the order of hundreds per second
  (signature operations dominate). For a production fleet at issuance
  time (fresh batch enrollments), this is fine; for steady-state
  enrollment after the initial provisioning, you're issuing on the
  order of hundreds-to-thousands per day.

### When to scale out

* If issuance latency starts dominating the enrollment plug's p99, or
* If signing-key custody requires HSM (regulatory, customer
  requirement).

### How

* **HSM / PKCS#11 strategy** in `ash_pki`. Interface is designed; the
  software-key descriptor is opaque, so the strategy-swap is a
  one-attribute change on `CertificateAuthority`.
* **Split bootstrap and operational CA hierarchies.** The framework
  already supports nested intermediates; an offline root + online
  bootstrap intermediates + per-tenant operational intermediates is a
  textbook split.

## Tracking your position

Telemetry the framework already emits:

* Ingest plug → `:telemetry` events under `[:soot_telemetry, :ingest]`
  (per-batch byte / sequence / latency).
* Rate limiter rejections under `[:soot_telemetry, :rate_limited]`.
* PKI issuance / revocation under `[:ash_pki, :certificate, …]`.

Wire these to your metrics backend and watch:

* **app CPU + scheduler queues** — Layer 1 ceiling.
* **broker concurrent connections** — Layer 2 ceiling.
* **Postgres write latency** — Layer 3 ceiling.
* **ClickHouse merge lag** — Layer 4 ceiling.
* **Cert issuance latency p99** — Layer 5 ceiling.
