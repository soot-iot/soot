# Soot — Generator Specification

**Status:** Shipped 2026-04-26
**Audience:** Implementers landing the per-library Igniter installers
and the umbrella `soot.install` orchestration. Read alongside
`UI-SPEC.md` (which establishes the high-level installer contract);
this document is the precise file-by-file manifest of what each
installer scaffolds and what defaults the generator ships.

**Implementation status:** All seven per-library installers, the
umbrella `soot.install`, the example `--example` resources, and the
revamped `soot.demo.seed` shipped 2026-04-26. 598 tests pass across
the eight library repositories (ash_pki / ash_mqtt / soot_core /
soot_telemetry / soot_segments / soot_contracts / soot_admin / soot);
one pre-existing PKCS11 fixture failure in ash_pki is unrelated.

## 1. Purpose

`UI-SPEC.md` says "each library owns `mix <lib>.install`." It does not
say what files those installers create, what config keys they patch,
what the example resources look like, or what the framework's defaults
should be on a fresh project.

This document fills that gap and supersedes the old `mix soot.new`
template approach (and the `soot_example/` skeleton it produced —
deleted in this work).

## 2. Goals

1. **One command, working app.** `mix igniter.new my_iot --install soot
   --with phx.new` plus `mix ash.setup` plus `mix phx.server` lands at
   a Phoenix LiveView app with: device-facing endpoints listening on
   mTLS, default telemetry streams (cpu / memory / disk) ready to
   ingest, an outdoor-temperature example stream, an admin LiveView at
   `/admin`, demo data, and one signed-in admin user.
2. **`--example` is the default**, not an opt-in. A user evaluating
   the framework wants something to look at. The "non-default" data
   the example wires up — outdoor temperature, weather shadow toggle,
   device label — is what makes the demo concrete. An operator
   shipping production passes `--no-example` (and `--no-demo-seed`).
3. **Defaults match what every IoT deployment cares about.** CPU,
   memory and disk are not application-specific — they're the
   reflexive starting point for any device fleet. They ship as
   first-class telemetry stream modules, not example data.
4. **Examples target the device side too.** The temperature stream,
   the `weather_*` shadow keys, and the `label` shadow key are the
   shape of a real device integration. `soot_nerves_example/` (or
   wherever the device-side example lives — separate work) consumes
   exactly this contract.

## 3. Bootstrap Flow (canonical)

```sh
mix archive.install hex igniter_new
mix archive.install hex phx_new
mix igniter.new my_iot \
    --install soot \
    --with phx.new \
    --with-args="--no-mailer --database postgres"
cd my_iot
mix ash.setup
mix phx.server
```

`--example` is implied. To opt out:

```sh
mix igniter.new my_iot --install soot --with phx.new \
    --with-args="--no-mailer --database postgres" \
    --no-example
```

After `mix phx.server`, the operator opens `http://localhost:4000` and:

- `/sign-in` — `ash_authentication_phoenix` sign-in page.
- `/admin` — admin LiveView, redirects to sign-in if not authenticated.
- `/admin/devices` — Cinder table of seeded demo devices.
- `/admin/telemetry` — list of streams (cpu, memory, disk, outdoor_temperature).
- `/enroll`, `/ingest/:stream`, `/.well-known/soot/contract` — device pipeline (mTLS-only).

Demo credentials are printed to the console at the end of `mix
ash.setup` (the demo seed runs as a `delay_task` after migrations).

## 4. Removed

- `/home/lawik/sprawl/soot/soot_example/` — the old `mix soot.new`
  output. Deleted in this work; it was a stub `Plug.Router` skeleton
  with nothing wired up. The new generator path replaces it.
- The `soot_example` reference is removed from any docs that pointed
  at it.

## 5. Default telemetry streams (always present)

These ship as stream modules in the **operator's project**, scaffolded
by `soot_telemetry.install`. They use `use SootTelemetry.Stream` and
register at compile time. Operator owns them post-install — they can
edit, extend, or delete.

### `MyIotWeb.Telemetry.Cpu`

```elixir
defmodule MyIot.Telemetry.Cpu do
  use SootTelemetry.Stream

  telemetry_stream do
    name :cpu
    tenant_scope :per_tenant
    retention months: 6

    fields do
      field :ts, :timestamp_us, required: true
      field :ingest_ts, :timestamp_us, server_set: true
      field :device_id, :string, dictionary: true
      field :tenant_id, :string, dictionary: true, server_set: true
      field :sequence, :uint64, monotonic: true

      field :load_1m, :float32
      field :load_5m, :float32
      field :load_15m, :float32
      field :user_pct, :float32
      field :system_pct, :float32
      field :iowait_pct, :float32
    end

    clickhouse do
      engine "MergeTree"
      order_by [:tenant_id, :device_id, :ts]
      partition_by "toYYYYMM(ts)"
    end
  end
end
```

### `MyIot.Telemetry.Memory`

Fields: `total_bytes`, `used_bytes`, `available_bytes`, `cached_bytes`,
`swap_used_bytes`, `swap_total_bytes`. All `:uint64`. Same envelope
fields (ts / ingest_ts / device_id / tenant_id / sequence). Same
ClickHouse settings. Retention 6 months.

### `MyIot.Telemetry.Disk`

Fields: `mount_point` (`:string`, dictionary), `total_bytes`,
`used_bytes`, `available_bytes`, `inode_total`, `inode_used`. Same
envelope. Retention 6 months.

These three modules are added to `config :my_iot, ash_domains:` (via
the telemetry domain's stream registry) and to the contract bundle by
default.

## 6. Example resources (`--example`, default ON)

The `--example` flag (default: true at the umbrella level) plants
illustrative resources that demonstrate non-default data ingest and
shadow control. The user passes `--no-example` to skip.

### Example telemetry stream — `MyIot.Telemetry.OutdoorTemperature`

```elixir
defmodule MyIot.Telemetry.OutdoorTemperature do
  use SootTelemetry.Stream

  telemetry_stream do
    name :outdoor_temperature
    tenant_scope :per_tenant
    retention months: 24

    fields do
      field :ts, :timestamp_us, required: true
      field :ingest_ts, :timestamp_us, server_set: true
      field :device_id, :string, dictionary: true
      field :tenant_id, :string, dictionary: true, server_set: true
      field :sequence, :uint64, monotonic: true

      field :celsius, :float32, required: true
      field :humidity_pct, :float32
      field :sensor_id, :string, dictionary: true
    end

    clickhouse do
      engine "MergeTree"
      order_by [:tenant_id, :device_id, :ts]
      partition_by "toYYYYMM(ts)"
    end
  end
end
```

### Example shadow — `MyIot.Devices.Device.Shadow`

This is the per-device shadow declaration consumed by `ash_mqtt`'s
shadow DSL and by `SootCore.DeviceShadow` storage. Three keys, each
demonstrates a different shadow pattern:

- `:weather_enabled` — boolean toggle. Shows binary control surfaces.
- `:weather_interval_s` — integer (seconds). Shows numeric tunables.
- `:label` — free-form string. Shows operator-set device metadata
  that the device echoes back into `reported`.

```elixir
defmodule MyIot.Devices.Device.Shadow do
  use AshMqtt.Shadow

  shadow do
    desired do
      field :weather_enabled, :boolean, default: true,
            doc: "If false, device pauses outdoor_temperature publishing."
      field :weather_interval_s, :integer, default: 60,
            doc: "Seconds between outdoor_temperature samples."
      field :label, :string,
            doc: "Free-form operator-set label. Echoed in reported state."
    end

    reported do
      field :weather_enabled, :boolean
      field :weather_interval_s, :integer
      field :label, :string
      field :firmware_version, :string
      field :uptime_s, :integer
    end
  end
end
```

### Example seed data (`mix soot.demo.seed`, run automatically after
`ash.setup` when `--example`)

- Tenant: `demo`.
- Serial scheme: `DEMO-{seq:6}`.
- Production batch of 5 devices, all `:operational` (so the admin UI
  has fully-provisioned devices to render).
- Admin user printed to stdout.
- Pre-populated shadow desired state on each device:
  `{weather_enabled: true, weather_interval_s: 60, label: "lab-#{i}"}`.

## 7. Per-library installer manifest

Each installer is a `use Igniter.Mix.Task` module. All:

- Are idempotent: detect existing state via
  `Igniter.Project.Module.module_exists?/2` and `move_to/2` against
  well-known anchors.
- Use `Igniter.Project.Config.configure/4` to patch config files
  (atomic, idempotent).
- Use `Igniter.Libs.Phoenix.{select_router, append_to_pipeline,
  add_scope, has_pipeline}` for router work.
- Emit one `Igniter.add_notice/2` summarizing changes + manual steps.
- Add themselves to the `composes:` of `soot.install`.

### `mix ash_pki.install` (in `ash_pki/`)

Background: `AshPki.Domain` is a concrete library module with the four
PKI resources already declared. The installer **registers** that
domain in the operator's project rather than generating copies.

Creates:

- `priv/pki/.gitkeep` — placeholder for runtime PEMs.

Patches:

- `.formatter.exs`: add `ash_pki` to `:import_deps`.
- `config/config.exs`: append `AshPki.Domain` to `config :<app>,
  :ash_domains`.
- `config/dev.exs`: configure `AshPki` software-key strategy +
  `ca_dir: "priv/pki/dev"`.
- `config/test.exs`: same with `priv/pki/test`.
- `config/runtime.exs`: production PKI env-var pulls
  (`SOOT_TRUST_BUNDLE`, `SOOT_SERVER_CHAIN`, `SOOT_SERVER_KEY`).

Notice: tells the operator to run `mix ash_pki.init --out priv/pki/dev`
once before first boot.

### `mix soot_core.install` (in `soot_core/`)

Background: `SootCore.Domain` ships with `Tenant`, `SerialScheme`,
`ProductionBatch`, `Device`, `DeviceShadow`, `EnrollmentToken` already
defined. The installer registers it.

Patches:

- `.formatter.exs`: add `soot_core` to `:import_deps`.
- `config/config.exs`: append `SootCore.Domain` to `:ash_domains`.
- Router (`MyIotWeb.Router`): add `:device_mtls` pipeline if not
  present; add `forward "/enroll", SootCore.Plug.Enroll` inside it.

Composes: `ash_pki.install` (must run first).

### `mix ash_mqtt.install` (in `ash_mqtt/`)

Creates:

- `priv/broker/.gitkeep` — output dir for `mix soot.broker.gen_config`.

Patches:

- `.formatter.exs`: add `ash_mqtt` to `:import_deps`.
- `config/config.exs`: `config :ash_mqtt, broker_config_dir: "priv/broker"`.

Notice: tells the operator how to invoke `mix soot.broker.gen_config
--resource …` once they've declared resources.

### `mix soot_telemetry.install` (in `soot_telemetry/`)

Background: `SootTelemetry.Domain` ships with `Schema`, `StreamRow`,
`IngestSession` already defined. Stream **DSL modules** (`use
SootTelemetry.Stream`) are operator-owned because they encode each
operator's specific schema choices — those are the files this
installer scaffolds.

Creates:

- **`lib/<app>/telemetry/cpu.ex`** — default cpu stream module (§5).
- **`lib/<app>/telemetry/memory.ex`** — default memory stream module.
- **`lib/<app>/telemetry/disk.ex`** — default disk stream module.
- `priv/migrations/clickhouse/.gitkeep` — output dir for ClickHouse SQL.

Patches:

- `.formatter.exs`: add `soot_telemetry` to `:import_deps`.
- `config/config.exs`: append `SootTelemetry.Domain` to `:ash_domains`.
- `config/runtime.exs`: ClickHouse URL pull (`CLICKHOUSE_URL`).
- Router: add `forward "/ingest", SootTelemetry.Plug.Ingest` inside
  the `:device_mtls` scope (created by `soot_core.install` earlier).

If `--example`:

- Also creates `lib/<app>/telemetry/outdoor_temperature.ex` (§6).

Composes: `soot_core.install`.

### `mix soot_segments.install` (in `soot_segments/`)

Background: `SootSegments.Domain` ships its resources. Segment DSL
modules are operator-owned but none ship by default — operators define
them after deciding which streams to summarize.

Patches:

- `.formatter.exs`: add `soot_segments` to `:import_deps`.
- `config/config.exs`: append `SootSegments.Domain` to `:ash_domains`.

Composes: `soot_telemetry.install`.

### `mix soot_contracts.install` (in `soot_contracts/`)

Background: `SootContracts.Domain` ships its resources.

Creates:

- `priv/contracts/.gitkeep`.

Patches:

- `.formatter.exs`: add `soot_contracts` to `:import_deps`.
- `config/config.exs`: append `SootContracts.Domain` to `:ash_domains`;
  `config :soot_contracts, output_dir: "priv/contracts"`.
- `config/runtime.exs`: `SOOT_CONTRACT_SIGNING_CA` env-var pull.
- Router: add `forward "/.well-known/soot/contract",
  SootContracts.Plug.WellKnown` inside `:device_mtls` scope.

Composes: `soot_segments.install`.

### `mix soot_admin.install` (in `soot_admin/`)

Creates:

- `lib/<app>_web/components/admin_layouts.ex` — sidebar layout.
- `lib/<app>_web/components/admin_nav.ex` — derived from
  `SootAdmin.Catalog`.
- `lib/<app>_web/live/admin/overview_live.ex` — small dashboard.
- `lib/<app>_web/live/admin/devices_live.ex`
- `lib/<app>_web/live/admin/enrollment_live.ex`
- `lib/<app>_web/live/admin/certificates_live.ex`
- `lib/<app>_web/live/admin/telemetry_live.ex`
- `lib/<app>_web/live/admin/segments_live.ex`

Each LiveView is < 60 lines, mounts `LiveUserAuth.live_user_required`,
and renders one `SootAdmin.*` Cinder component.

Patches:

- Router: add `/admin` scope with `ash_authentication_live_session
  :admin` containing the six `live` routes (UI-SPEC §5).

Composes: nothing (it's a leaf — `soot.install` runs it last).

### `mix soot.install` (in `soot/`, already exists)

Updates needed:

- Default `--example` to `true` (currently defaults to `false`). Pass
  `--example` through to every child via `argv`.
- Schedule `Igniter.delay_task("soot.demo.seed", ["--example"])` when
  `--example` is on (currently does this but only when explicitly
  set).
- Remove the warning-and-skip path for missing child installers — by
  the time this lands, every child must exist.

If `--example`:

- Generate `lib/<app>/devices/device/shadow.ex` (the `AshMqtt.Shadow`
  declaration from §6).

## 8. Demo seed updates

`mix soot.demo.seed` (in `soot/`) needs:

- Replace the `vibration` stream with `outdoor_temperature` (when
  `--example`).
- Provision 5 devices in `:operational` state (not 25 unprovisioned)
  so the admin UI shows green dots, not pending enrollment.
- Pre-populate each device's shadow desired state with
  `weather_enabled: true, weather_interval_s: 60, label: "lab-#{i}"`.
- Print the demo URL + admin credentials clearly.

The simulator path (`--simulator`) still inserts fake telemetry but
now targets `outdoor_temperature` (oscillating sine wave around 18°C
with humidity 40-70%) so the admin's telemetry panel has moving data.

## 9. Idempotency contract

Every installer must:

- Re-run as a no-op on an already-installed project. Test: run twice
  in a row; `git diff` between runs is empty.
- Detect an already-mounted scope by walking the router AST for an
  anchor (e.g. `forward "/enroll", SootCore.Plug.Enroll` is the
  unique anchor for the device scope).
- Detect an existing domain by checking `Igniter.Project.Config` for
  the domain module already in `:ash_domains`.
- For LiveView and component generation, check
  `Igniter.Project.Module.module_exists?/2`; if present, leave it
  alone (operator may have edited).

## 10. Test strategy

Each library ships an integration test:

```elixir
defmodule MixTasks.<Lib>.InstallTest do
  use ExUnit.Case
  import Igniter.Test

  test "scaffolds a minimal Phoenix project" do
    test_project()
    |> Igniter.compose_task("<lib>.install", [])
    |> assert_creates("lib/test/<domain>.ex")
    |> assert_has_patch("config/config.exs", ~r/ash_domains/)
  end

  test "is idempotent" do
    test_project()
    |> Igniter.compose_task("<lib>.install", [])
    |> Igniter.compose_task("<lib>.install", [])
    |> assert_unchanged_after_second_run()
  end
end
```

The umbrella `soot/` ships a slower end-to-end test that:

1. Spawns `mix igniter.new test_app --with phx.new ...` in a tmp dir.
2. Runs `mix igniter.install soot --example`.
3. Runs `mix ash.setup` (with a stubbed Postgres + ClickHouse).
4. `mix phx.server &`, `curl http://localhost:4000/admin`, asserts a
   redirect to `/sign-in`.

This is the "would the README copy-paste actually work?" test.

## 11. Implementation phases

Smaller than UI-SPEC §10 because the high-level design is already
locked in:

### Phase G1 — Foundation

- Delete `soot_example/`.
- Default `mix soot.install --example` ON.
- Update `mix soot.demo.seed` to plant `outdoor_temperature` + shadow.

### Phase G2 — Per-library installers

In dependency order: `ash_pki.install` → `soot_core.install` →
`ash_mqtt.install` → `soot_telemetry.install` (with default streams)
→ `soot_segments.install` → `soot_contracts.install` →
`soot_admin.install`.

Each one ships with the per-library integration test from §10.

### Phase G3 — End-to-end test

The umbrella's golden-path test. Slow, but the only way to catch
"installer A and installer B both edit the router and one stomps the
other."

Phases run in order; G2's installers can be parallelized by owner
once G1 lands.

## 12. Open questions

- **DaisyUI default vs opt-in?** UI-SPEC §11 left this open. Pin to
  vanilla Tailwind for now; switch when the admin UI lands and we see
  whether the components look acceptable in plain Tailwind.
- **Should `soot_telemetry.install` register the default streams in
  the operator's contract bundle automatically?** Yes — the contract
  bundle is what devices fetch to learn the schema. Default streams
  not in the bundle = devices can't push to them.
- **Does `--example` install the device-side example too?** No.
  Device-side example (Nerves) lives in a separate repo and a
  separate generator. The flag just makes the *backend* aware that
  outdoor_temperature is a real stream.
