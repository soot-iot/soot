# Soot

IoT framework on Ash. See [`SPEC.md`](SPEC.md) for the full design.

The framework is split across several repos. The `ash_*` prefix marks
libraries that stand alone outside this framework; `soot_*` marks libraries
that are framework-coupled. Each library has its own repo and is released
independently.

## Repos

| Library | Phase | Repo / status |
|---|---|---|
| `ash_pki`            | 1 | separate repo (working: CA hierarchy, cert issuance/revocation, CRLs, mTLS plug, mix tasks) |
| `soot_core`          | 2 | not started |
| `ash_mqtt`           | 3 | not started |
| `soot_telemetry`     | 4 | not started |
| `soot_segments`      | 5 | not started |
| `soot_contracts`     | 6 | not started |
| `soot_admin`         | 6 | not started |
| `soot` (umbrella meta) | 6 | not started |
