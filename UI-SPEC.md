# Soot — UI & Generator Specification

**Status:** Draft v1
**Audience:** Library implementers picking up Phase 6 (and the generator
revamp it implies). Read alongside `SPEC.md`; this document refines
sections 5.7 (`soot_admin`), 5.8 (`soot` umbrella / `mix soot.new`), and
the Phase 6 scope.

## 1. Purpose

`SPEC.md` defines the framework's backend libraries. It is intentionally
quiet on two adjacent concerns:

- How an operator goes from "empty machine" to "running app with admin
  UI and the device-facing endpoints wired up" in one command.
- What the admin LiveView app actually looks like, beyond "drop in
  `soot_admin` Cinder components."

This document specifies both. The generator is the front door to the
framework, and the admin UI is what the operator stares at every day —
both deserve the same level of design rigor as the resource model.

## 2. Principles

1. **`phx.new` is the substrate, not a parallel track.** The generated
   project is a normal Phoenix app — assets pipeline, router,
   `LiveView`, `Endpoint`, the lot. Soot does not ship a parallel
   "lite" web stack. An operator who already knows Phoenix should
   recognize everything in the generated tree.
2. **Igniter installers are the composition mechanism.** Each library
   owns its `mix <lib>.install` and is responsible for patching the
   operator's project (router, config, application supervisor, AGENTS
   markdown) idempotently. The umbrella `soot.install` composes them.
   This mirrors `ash_authentication_phoenix.install` and
   `ash_admin.install` exactly; we are not inventing a new pattern.
3. **One command from clean machine to running demo.**
   `mix igniter.new my_iot --install soot --with phx.new` plus
   `mix ash.setup` should land an operator at a working app with seeded
   demo data, an admin LiveView they can log in to, and the
   device-facing endpoints listening on mTLS. No undocumented manual
   steps in between.
4. **Phoenix hosts both surfaces; mTLS is per-route, not per-app.** The
   device-facing endpoints (`/enroll`, `/ingest/:stream`,
   `/.well-known/soot/contract`) live in the same Phoenix endpoint as
   the admin UI but in a dedicated pipeline that runs `AshPki.Plug.MTLS`
   and rejects everything that does not present a valid client cert.
   The default topology runs both behind the same Bandit listener; an
   operator who wants two listeners (one mTLS, one TLS-only for admin)
   gets a documented `--split-endpoints` flag.
5. **`soot_admin` ships building blocks AND a generator that uses
   them.** SPEC §4 keeps `soot_admin` as components-only. That stays
   true for the *library*; the *installer* is the part that wires the
   components into an operator's LiveView app. An operator can
   uninstall the wiring and keep the components, or never run the
   installer and compose the components themselves.
6. **Generated code is the operator's code, not framework runtime.**
   Once the installer has run, the operator owns every file under
   `lib/my_iot_web/` — router, layouts, the admin LiveView, the auth
   controller. The framework never reaches into those files at runtime;
   re-running the installer is opt-in and idempotent.
7. **Authentication is `ash_authentication_phoenix`, not bespoke.** The
   admin actor is a normal `ash_authentication` user. We do not ship a
   Soot-specific identity model for operators.

## 3. Bootstrap Flow

The canonical "from clean machine" invocation:

```sh
mix archive.install hex igniter_new
mix archive.install hex phx_new
mix igniter.new my_iot \
    --install soot \
    --with phx.new \
    --with-args="--database postgres"
cd my_iot
mix ash.setup
mix soot.demo.seed   # optional
mix phx.server
```

What happens, in order:

1. `mix igniter.new my_iot --with phx.new` invokes
   `mix phx.new my_iot --database postgres --install`
   (the `--install` flag tells `phx.new` to skip the post-generation
   prompt; `igniter.new` injects it automatically when `--with` is
   `phx.new`).
2. Phoenix's normal generator runs and produces a standard project
   tree.
3. `igniter.new` then runs `mix igniter.install soot` inside the new
   project. `soot.install` composes every per-library installer (see
   §4) and patches the project files in one transactional pass.
4. The operator runs `mix ash.setup`, which composes
   `ash.codegen`, `ecto.create`, `ecto.migrate`, and any
   resource-specific setup tasks the installers registered.
5. Optional: `mix soot.demo.seed` plants a tenant, a serial scheme, a
   batch of simulated devices, an admin user, and a couple of telemetry
   streams so the admin UI has something to render on first boot.

The operator should be able to copy-paste this block from the README and
end at a working demo. If any step requires editing a file by hand, the
generator is incomplete.

## 4. Installer Composition

`mix igniter.install soot` is a thin coordinator. It composes the
following tasks in order, each owned by its library:

| Order | Task | Owner | Responsibility |
|---|---|---|---|
| 1 | `ash.install` | `ash` | Standard Ash bootstrap (formatter, config, backwards-compat flags). Same as Ash's documented installer. |
| 2 | `ash_postgres.install` | `ash_postgres` | Repo, dev/test config, `ash.codegen` integration. |
| 3 | `ash_phoenix.install` | `ash_phoenix` | `AshPhoenix.Plug.CheckCodegenStatus` wired into the `Endpoint`. AGENTS.md cleanup. |
| 4 | `ash_authentication.install` | `ash_authentication` | `Accounts` domain, `User` and `Token` resources, password strategy by default. |
| 5 | `ash_authentication_phoenix.install` | `ash_authentication_phoenix` | Sign-in routes, `AuthController`, `LiveUserAuth`, browser pipeline plugs. |
| 6 | `ash_pki.install` | `ash_pki` | `Pki` domain, `CertificateAuthority` / `Certificate` / `RevocationList` resources, `priv/pki/` placeholder, dev/test config for the software key strategy. |
| 7 | `soot_core.install` | `soot_core` | `Devices` domain, `Tenant` / `SerialScheme` / `ProductionBatch` / `Device` / `EnrollmentToken` resources, state machine, multi-tenancy policy helpers. |
| 8 | `ash_mqtt.install` | `ash_mqtt` | Formatter import, broker config output dir, `mosquitto.conf` template wiring. No router changes (MQTT is broker-side). |
| 9 | `soot_telemetry.install` | `soot_telemetry` | `Telemetry` domain, `Schema` / `Stream` / `IngestSession` resources, ClickHouse connection config, `priv/migrations/clickhouse/` directory. |
| 10 | `soot_segments.install` | `soot_segments` | `Segments` domain, `Segment` / `SegmentVersion` resources. |
| 11 | `soot_contracts.install` | `soot_contracts` | `Contracts` domain, `priv/contracts/` output dir, signing key config. |
| 12 | `soot.install` (web) | `soot` | Mounts the device-facing pipeline in the router (see §5), renders `lib/my_iot_web/admin_layouts.ex`, adds the `mix soot.demo.seed` task. |
| 13 | `soot_admin.install` | `soot_admin` | Generates `MyIotWeb.AdminLive` LiveView, an admin layout, a tab strip, mounts the Cinder components on routes. Wires `live_session` with `LiveUserAuth.live_user_required`. |

Order matters: every step downstream of `ash_authentication.install`
relies on a `User` actor existing; every step downstream of
`soot_core.install` relies on the `Tenant` resource. The umbrella
installer enforces order by `Igniter.compose_task/2` and surfaces a
clear error if the operator already has an incompatible domain
present.

### Library installer contract

Each `mix <lib>.install` MUST:

- Be a `use Igniter.Mix.Task` module guarded by
  `Code.ensure_loaded?(Igniter)` (with a fallback `use Mix.Task`
  module that errors helpfully when igniter is not present), exactly
  matching the Ash project pattern.
- Be **idempotent.** Re-running the installer must be a no-op on an
  already-installed project. Installers detect existing state via
  `Igniter.Project.Module.module_exists/2`,
  `Igniter.Code.Common.move_to/2` against well-known anchor calls
  (e.g. `use AshAuthentication.Phoenix.Router`), and friends.
- Use `Igniter.Libs.Phoenix.select_router/2` if it needs to patch a
  router (auto-pick the only router; prompt if there are multiple).
- Use `Igniter.Libs.Phoenix.append_to_pipeline/3`,
  `Igniter.Libs.Phoenix.add_scope/3`, and
  `Igniter.Libs.Phoenix.endpoints_for_router/2` rather than rolling
  its own router-patching primitives. These are stable across
  igniter versions.
- Emit a `notice` (via `Igniter.add_notice/2`) summarizing what it
  changed and what manual steps, if any, the operator should take.
- Add itself to `composes:` of `soot.install` so the umbrella's option
  schema is the union of its children's schemas. (This is the same
  mechanism `ash_authentication_phoenix.install` uses to compose
  `ash_authentication.install` and the strategy tasks.)
- Provide an `--example` switch where it makes sense, calling its
  library's `mix <lib>.gen.*` tasks to plant illustrative resources.
  The `--example` flag at the umbrella level fans out to children.

Each `mix <lib>.install` MUST NOT:

- Modify files outside the project root.
- Touch the database directly. Schema work goes through
  `Igniter.delay_task("ash.setup")` so it runs after the file changes
  land.
- Make assumptions about the operator's `Phoenix` version or
  `Tailwind` setup beyond what the standard `phx.new` ships.
- Hard-fail on an existing customized router. Installers should add
  warnings with a copy-pasteable snippet when they cannot safely
  patch.

## 5. Generated Project Structure

After `mix igniter.new my_iot --install soot --with phx.new`, the
project tree adds the following on top of standard Phoenix output:

```
my_iot/
├── lib/
│   ├── my_iot/
│   │   ├── accounts/                # ash_authentication.install
│   │   │   ├── user.ex
│   │   │   └── token.ex
│   │   ├── accounts.ex              # Accounts domain
│   │   ├── pki/                     # ash_pki.install
│   │   │   ├── certificate_authority.ex
│   │   │   ├── certificate.ex
│   │   │   └── revocation_list.ex
│   │   ├── pki.ex
│   │   ├── devices/                 # soot_core.install
│   │   │   ├── tenant.ex
│   │   │   ├── serial_scheme.ex
│   │   │   ├── production_batch.ex
│   │   │   ├── device.ex
│   │   │   └── enrollment_token.ex
│   │   ├── devices.ex
│   │   ├── telemetry/               # soot_telemetry.install
│   │   │   ├── schema.ex
│   │   │   ├── stream.ex
│   │   │   └── ingest_session.ex
│   │   ├── telemetry.ex
│   │   ├── segments/                # soot_segments.install
│   │   │   ├── segment.ex
│   │   │   └── segment_version.ex
│   │   ├── segments.ex
│   │   ├── contracts.ex             # soot_contracts.install
│   │   └── repo.ex
│   └── my_iot_web/
│       ├── router.ex                # patched by every web installer
│       ├── endpoint.ex              # patched by ash_phoenix.install
│       ├── controllers/
│       │   ├── auth_controller.ex   # ash_authentication_phoenix.install
│       │   └── enroll_controller.ex # soot.install (or Plug.Router-style mount)
│       ├── live/
│       │   ├── live_user_auth.ex    # ash_authentication_phoenix.install
│       │   └── admin/               # soot_admin.install
│       │       ├── overview_live.ex
│       │       ├── devices_live.ex
│       │       ├── enrollment_live.ex
│       │       ├── certificates_live.ex
│       │       ├── telemetry_live.ex
│       │       └── segments_live.ex
│       ├── components/
│       │   ├── admin_layouts.ex     # soot_admin.install
│       │   └── admin_nav.ex         # soot_admin.install
│       └── plug/
│           └── ingest.ex            # soot_telemetry.install (router-mounted Plug)
├── priv/
│   ├── pki/                         # ash_pki.install
│   ├── contracts/                   # soot_contracts.install
│   ├── broker/                      # soot.install
│   ├── migrations/clickhouse/       # soot_telemetry.install
│   └── repo/seeds.exs               # soot.install: optional demo seed entrypoint
├── config/
│   ├── config.exs                   # patched by every installer
│   ├── dev.exs
│   ├── test.exs
│   └── runtime.exs                  # patched: PKI paths, ClickHouse URL, broker
└── AGENTS.md                        # patched by ash_phoenix.install
```

### Router shape

The router has three concerns and three pipelines:

```elixir
defmodule MyIotWeb.Router do
  use MyIotWeb, :router
  use AshAuthentication.Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MyIotWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
    plug :set_actor, :user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :load_from_bearer
    plug :set_actor, :user
  end

  pipeline :device_mtls do
    plug AshPki.Plug.MTLS, require_known_certificate: true
  end

  # Sign-in / register / reset / sign-out — ash_authentication_phoenix.install
  scope "/", MyIotWeb do
    pipe_through :browser

    auth_routes AuthController, MyIot.Accounts.User, path: "/auth"
    sign_out_route AuthController
    sign_in_route register_path: "/register",
                  reset_path: "/reset",
                  on_mount: [{MyIotWeb.LiveUserAuth, :live_no_user}]
  end

  # Admin LiveView — soot_admin.install
  scope "/admin", MyIotWeb do
    pipe_through :browser

    ash_authentication_live_session :admin,
      on_mount: [{MyIotWeb.LiveUserAuth, :live_user_required}] do
      live "/", Admin.OverviewLive, :index
      live "/devices", Admin.DevicesLive, :index
      live "/enrollment", Admin.EnrollmentLive, :index
      live "/certificates", Admin.CertificatesLive, :index
      live "/telemetry", Admin.TelemetryLive, :index
      live "/segments", Admin.SegmentsLive, :index
    end
  end

  # Device-facing endpoints — soot.install
  scope "/" do
    pipe_through :device_mtls

    forward "/enroll", SootCore.Plug.Enroll
    forward "/ingest", SootTelemetry.Plug.Ingest
    forward "/.well-known/soot/contract", SootContracts.Plug.WellKnown
  end
end
```

Notes:

- The mTLS pipeline runs `AshPki.Plug.MTLS` *before* `:match` /
  `:dispatch` so that an unauthenticated request never reaches the
  forwarded plugs. The plug exposes the verified cert as
  `conn.assigns.actor` for downstream Ash policies.
- The `forward`s mount the framework-shipped plugs directly. The
  installer does not generate a controller stub; the plugs are part of
  the library and the operator does not own them by default. (Operator
  CAN replace a `forward` with their own controller — this is an
  escape hatch, not the default path.)
- Sign-in lives at `/sign-in` and admin at `/admin/*`. The two are
  distinct scopes so an operator can swap auth providers without
  touching admin routes.

### Endpoint shape

`MyIotWeb.Endpoint` is a standard Phoenix endpoint. The Bandit
configuration is wired by the operator's `runtime.exs`:

```elixir
# config/runtime.exs (patched by soot.install)
if config_env() == :prod do
  config :my_iot, MyIotWeb.Endpoint,
    https: [
      port: 4001,
      cipher_suite: :strong,
      cacertfile: System.fetch_env!("SOOT_TRUST_BUNDLE"),
      certfile: System.fetch_env!("SOOT_SERVER_CHAIN"),
      keyfile: System.fetch_env!("SOOT_SERVER_KEY"),
      verify: :verify_peer,
      fail_if_no_peer_cert: false   # admin pipeline accepts no-cert
    ],
    adapter: Bandit.PhoenixAdapter
end
```

`fail_if_no_peer_cert: false` is deliberate. The TLS handshake accepts
both cert-presenting and cert-less clients; the `:device_mtls`
pipeline's `AshPki.Plug.MTLS` is what enforces the cert requirement on
device routes. Admin browser sessions go through the same listener
without needing a client cert.

### `--split-endpoints` (documented escape hatch)

Operators behind a TLS-terminating LB or with strict separation
requirements can pass `--split-endpoints` to the umbrella installer.
This generates a second endpoint module `MyIotWeb.DeviceEndpoint`
listening on a separate port with `fail_if_no_peer_cert: true`, and
moves the `:device_mtls` scope's routes onto a `MyIotWeb.DeviceRouter`
mounted in that endpoint. The single-endpoint default is documented as
"correct for >90% of deployments"; the split is the same code paths
just hosted differently.

## 6. Admin UI Surface

What `soot_admin.install` generates and what the admin operator sees on
first boot.

### Layout

The admin app uses a sidebar layout with one section per resource
domain:

```
┌─────────────────┬────────────────────────────────────────────┐
│ MyIot Admin     │  Devices                              ⚙    │
│                 ├────────────────────────────────────────────┤
│ ▸ Overview      │  [Filter: tenant ▼ ] [Filter: state ▼ ]    │
│ ▸ Devices       │  [Search serial               ]            │
│ ▸ Enrollment    │  ──────────────────────────────────────────│
│ ▸ Certificates  │  Serial   State        Tenant   Last seen  │
│ ▸ Telemetry     │  AB1234   operational  acme     2m ago     │
│ ▸ Segments      │  AB1235   bootstrapped acme     —          │
│                 │  …                                         │
│                 │  [pagination]                              │
│                 │                                            │
│ acme@local      │                                            │
│ Sign out        │                                            │
└─────────────────┴────────────────────────────────────────────┘
```

Generated as `MyIotWeb.AdminLayouts` plus `MyIotWeb.AdminNav`. The
sidebar items are derived at compile time from the admin resource
catalog (see below) so adding a new admin tab is a single-file change.

### Pages

Each admin tab is a `LiveView` that hosts one Cinder component from
`soot_admin`. The generated LiveViews are intentionally thin — fewer
than 60 lines each — so the operator can read them and understand what
to change:

```elixir
defmodule MyIotWeb.Admin.DevicesLive do
  use MyIotWeb, :live_view
  on_mount {MyIotWeb.LiveUserAuth, :live_user_required}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Devices")}
  end

  def render(assigns) do
    ~H"""
    <.admin_layout active={:devices}>
      <SootAdmin.DeviceTable.table actor={@current_user} />
    </.admin_layout>
    """
  end
end
```

`OverviewLive` is the one custom LiveView — a small dashboard with
counts (`Devices.list_devices/0` aggregations) and the most recent
ingest sessions. It is intended as a hook for the operator to extend
with their own metrics.

### Theming

`soot_admin`'s components are vanilla Tailwind out of the box.
DaisyUI is detected (same way `ash_authentication_phoenix.setup` does
it — checking `assets/vendor/daisyui.js`) and the components switch to
DaisyUI primitives if present. No DaisyUI dependency is imposed.

### Resource catalog

`SootAdmin.Catalog` exposes the list of admin pages the framework
ships, as `[{slug, label, component_module}]`. The generated
`AdminNav` iterates this list. Operators add their own entries by
appending to the catalog (a `config :soot_admin, :extra_pages` list)
or by editing `AdminNav` directly. This is the seam where the
framework hands off to the operator's UX.

### What the installer does NOT generate

- **Custom dashboards.** Operators build those in their own LiveViews
  using `Segment.cinder_query/2` and the standard Cinder chart
  components.
- **A device console / SSH-like shell.** Out of scope per SPEC §5.7.
- **Real-time map views.** Same.
- **Per-tenant admin sub-apps.** Multi-tenancy in the admin is via
  filtering and policy, not separate installations.

## 7. Demo Seed (`mix soot.demo.seed`)

A separate mix task, generated by `soot.install`, that the operator
can run after `mix ash.setup` to make the freshly-installed admin app
non-empty:

- Create a `Tenant` named `demo`.
- Create a `SerialScheme` `DEMO-{seq:6}`.
- Create a `ProductionBatch` of 25 devices, all in `:unprovisioned`.
- Create an `Accounts.User` (`admin@example.com` / `demo-password`,
  printed to the console at the end).
- Create a `Telemetry.Stream` named `vibration` with three float fields
  and a `MergeTree` table.
- Create a `Segment` named `vibration_p95_hourly`.
- Optionally (`--simulator`) start a small `Task` that pretends to be
  enrolled devices pushing telemetry every few seconds, so the admin's
  Telemetry tab has data to display.

The demo seed is documented as "for development only — do not run in
production." The installer adds it to `priv/repo/seeds.exs` only when
invoked with `--example` (mirroring `ash.install --example`).

## 8. Replacing the Current `mix soot.new`

The existing `mix soot.new` (template-based, hex deps, no Phoenix) is
deleted outright in Phase 6b. Nothing is released yet, there are no
users to migrate, and a deprecation shim would just be dead code.

What gets removed:

- `lib/mix/tasks/soot.new.ex`
- `priv/templates/project/` (the four `.eex` template files)
- The "Generated by `mix soot.new`" line in any generated README.

The new path — `mix igniter.new my_iot --install soot --with phx.new` —
is documented in `soot`'s README and in the framework's docs as the
only way to start a project. There is no `mix soot.new` to find,
deprecate, or maintain.

If we later decide a non-Phoenix headless variant is worth shipping
(e.g. a "minimum-deps ingest-only service"), it goes in as a
`--profile` flag on the umbrella installer, not as a separate
generator.

## 9. Testing Infrastructure

Each library's installer ships an integration test that:

1. Creates a fresh project with `mix igniter.new test_app --with phx.new
   --with-args="--database postgres"` in a tmp dir.
2. Runs `mix igniter.install <lib>` and asserts the expected files
   exist with the expected anchor lines.
3. Runs `mix compile` and asserts it succeeds.
4. (Where applicable) Runs the library's own `mix test` against the
   generated project.

These tests are slow but high-signal. They run on every PR to the
library; failures gate merges.

The umbrella test runs the full bootstrap (`igniter.new` →
`soot.install` → `ash.setup` → `mix soot.demo.seed --simulator` →
`mix phx.server` background task → curl `/admin` and assert the
sign-in page renders) as a single golden-path test in CI. This is the
"would the README copy-paste actually work?" test.

## 10. Phase Plan

This work re-scopes the existing Phase 6 (`SPEC.md` §7) into three
sub-phases:

### Phase 6a — Per-library installers

Each library that does not already have an installer gets one. Owners
match SPEC §7's existing assignments: whoever owns the library owns
its installer. Scope per library is small (1-3 days each); the work
parallelizes cleanly because each installer is independent until
composition.

**Deliverables:**
- `mix ash_pki.install`, `mix soot_core.install`,
  `mix ash_mqtt.install`, `mix soot_telemetry.install`,
  `mix soot_segments.install`, `mix soot_contracts.install`,
  `mix soot_admin.install`.
- Per-library integration tests as described in §9.

**Non-goals:** the umbrella `soot.install`. Each library installer
must work standalone (`mix igniter.install soot_core` on a vanilla
Phoenix project should succeed).

### Phase 6b — Umbrella `soot.install` and demo seed

**Scope:**
- `mix soot.install` composes the per-library installers in the
  defined order with the right option-schema fan-out.
- `mix soot.demo.seed` generates plausible data across every domain.
- Update `mix soot.new` to the deprecation shim from §8.
- Generated app's README documents the bootstrap flow from §3.

**Deliverables:**
- The full bootstrap test from §9 passes in CI.
- README of `soot` package matches §3 verbatim.

### Phase 6c — Admin UI polish

**Scope:**
- `MyIotWeb.AdminLayouts`, `AdminNav`, and the `OverviewLive`
  dashboard.
- DaisyUI detection and theming.
- `SootAdmin.Catalog` extension mechanism.
- Documentation for "how to add your own admin tab" (one page in the
  generated README).

**Deliverables:**
- The screenshot in §6 matches what the freshly-generated admin app
  looks like.

Phases can run in parallel after Phase 6a's installer contract is
locked in. Phase 6c specifically can start as soon as
`soot_admin.install` exists in skeleton form.

## 11. Open Questions

These do not block implementation but should be resolved before Phase 6
ships.

- **DaisyUI default vs opt-in.** `phx.new` ships vanilla Tailwind.
  `ash_authentication_phoenix` switches to DaisyUI overrides if the
  vendor file is present. Cinder's documented theming story may
  differ. Should `--with-args="... --tailwind-daisyui"` be
  the recommended invocation, or should we let the operator opt in
  later?
- **Single endpoint vs split endpoints by default.** §5 picks single
  endpoint; SPEC §3's diagram implies the operator's app is one box.
  An operator behind a managed LB (Cloud Run, Fly Anycast) might find
  split easier to reason about. Reconsider after one operator deploys
  to production.
- **Should the device-facing pipeline live in `MyIotWeb.Router` or in
  a dedicated `DeviceRouter` even in the single-endpoint case?**
  Separate router would clarify ownership but adds a moving part. §5
  picks the single-router path; revisit if the router file gets
  unwieldy.
- **OAuth admin auth.** `ash_authentication_phoenix.install` supports
  `--auth-strategy oauth2,google` etc. Should `soot.install` expose
  the same flags so an operator can `--install soot --auth-strategy
  google` from the start? Probably yes; defer to Phase 6b.
- **What gets seeded by `--example` vs `--demo-seed`.** The Ash
  convention is `--example` plants illustrative resources at install
  time. The Soot convention here adds a separate mix task for runtime
  seeding. Reconcile naming: maybe the umbrella installer's
  `--example` flag should automatically schedule
  `Igniter.delay_task("soot.demo.seed")` after `ash.setup`.

## 12. Handoff Notes for Phase 6 Implementers

- **Read `ash_authentication_phoenix.install` and
  `ash_admin.install` first.** They are the closest existing
  reference for the kind of router-patching, controller-creation, and
  `live_session` wiring this work needs. Both are MIT-licensed and
  the patterns are directly portable.
- **Idempotency is a correctness property, not a nice-to-have.**
  Every installer is run by `igniter.new` exactly once on a clean
  project AND by operators on existing projects. The two paths must
  produce identical end states. Test both.
- **The router is a hot zone.** Multiple installers patch it.
  `Igniter.Libs.Phoenix.append_to_pipeline` and `add_scope` handle
  most cases cleanly; if you find yourself reaching for raw zipper
  manipulation, ask whether your installer is doing too much.
- **Do not import `Phoenix.LiveView` types into framework runtime
  code.** Generated LiveViews live in the operator's project and use
  Phoenix normally; the framework libraries themselves
  (`soot_admin/lib/`) only emit Phoenix components, never depend on
  the operator's web module.
- **The demo seed is part of the generator's contract.** Treat it as
  shippable code, not a throwaway script. It is what an evaluator
  runs in their first 10 minutes with the framework.
- **When in doubt, look at what `phx.new` produces and match that
  shape.** The operator should never need to ask "why does my Soot
  app look weird compared to a normal Phoenix app?"
