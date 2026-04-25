# Soot

IoT framework on Ash. See [`SPEC.md`](SPEC.md) for the full design.

The framework is split across several repos. The `ash_*` prefix marks
libraries that stand alone outside this framework; `soot_*` marks libraries
that are framework-coupled. Each library has its own repo and is released
independently.

## Repos

| Library | Phase | Repo / status |
|---|---|---|
| `ash_pki`              | 1   | separate repo, **landed** — CA hierarchy, cert issuance/revocation, CRLs, mTLS plug, mix tasks |
| `soot_core`            | 2   | separate repo, **landed** — Tenant, SerialScheme, ProductionBatch, Device + state machine, EnrollmentToken, `/enroll` plug |
| `ash_mqtt` (3a)        | 3a  | separate repo, **landed** — resource extension + broker config generation |
| `ash_mqtt` (3b)        | 3b  | not started — action invocation over MQTT 5, shadow DSL |
| `soot_telemetry`       | 4   | separate repo, **landed** — telemetry stream DSL, schema fingerprinting, ingest plug, ClickHouse DDL generator |
| `soot_segments`        | 5   | not started |
| `soot_contracts`       | 6   | not started |
| `soot_admin`           | 6   | not started |
| `soot` (umbrella meta) | 6   | not started |
