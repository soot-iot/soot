# Soot v0.1 — Production-Blocking Gaps

Findings from a sweep of the ten library repos under `sprawl/soot/`
looking for things v0.1 claimed shipped but that don't actually
function end-to-end. The bar: "would a real production deployment do
something useful, or does this just no-op / fail / lose data?"

Three blockers, plus context on what's already covered elsewhere and
what's verified working.

---

## Blockers

### 1. `SootTelemetry.Writer.Noop` is the default writer

`soot_telemetry/lib/soot_telemetry/writer.ex:38-44` — the only writer
implementation pattern-matches the batch shape and returns `:ok`
without doing anything. The ingest plug validates headers,
fingerprint, sequence, rate limits, and authorization, then hands the
Arrow body to a no-op. Nothing reaches ClickHouse.

Already captured in `SPEC-2.md` §3.1 / §5.1 (recast as Arrow-native
pass-through writer in Phase 7).

### 2. The entire OLTP layer is ETS-only — **resolved 2026-04-27**

**Status:** Fixed. Every resource now ships as a Spark `Ash.Resource`
extension under `<Lib>.Resource.<Name>` plus a thin `Ash.DataLayer.Ets`
default at `<Lib>.<Name>`. Consumers declare their own
`AshPostgres.DataLayer`-backed module + `postgres do … end` block,
apply the extension, and register via app config (e.g. `config
:soot_core, device: MyApp.Device`). The four libraries' own test
suites still run against the ETS defaults (369 tests passing across
`soot_core`/`soot_telemetry`/`soot_contracts`/`soot_segments`); a
consumer integration test in the `soot` umbrella will cover the
AshPostgres path.

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

### 3. Contract bundle signing only works with software CA keys — **in flight 2026-04-27**

**Status:** Two stacked PRs land the fix.

* [`soot-iot/ash_pki#2`](https://github.com/soot-iot/ash_pki/pull/2)
  adds `AshPki.KeyStrategy.sign(descriptor, body, opts)` — implemented
  for `Software` (`:public_key.sign/3`) and `Pkcs11` (engine-key
  reference). `Imported` returns `:no_signing_capability`; `KMS`
  returns `:not_implemented`. Tests cover the Software round-trip and
  add a SoftHSM2-tagged round-trip in the existing `:pkcs11`
  integration block.
* [`soot-iot/soot_contracts#3`](https://github.com/soot-iot/soot_contracts/pull/3)
  rewrites `Bundle.sign_body/2` to dispatch through the new callback.
  Errors from the strategy bubble up as `ArgumentError` with the
  underlying reason; the caller no longer assumes Software-only.
  Depends on `ash_pki#2` landing first.

Once both merge, HSM-backed CAs can sign bundles, and the v0.1
phase-6 "HSM-backed CA keys shipped" claim becomes accurate
end-to-end.

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
  config knob. Phase 7 entry added in `SPEC-2.md`.
* **HSM-aware bundle signing** — in flight (see Blocker 3 above).
  `AshPki.KeyStrategy.sign/3` lands in `ash_pki#2`;
  `SootContracts.Bundle.sign_body/2` rewrites in `soot_contracts#3`.
  Removes the hardcoded `Software` match.

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
