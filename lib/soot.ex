defmodule Soot do
  @moduledoc """
  Soot — IoT framework on Ash.

  This module is the umbrella entry point. The framework's
  functionality lives in the constituent libraries — see
  `libraries/0` for the canonical list (kept in sync with the
  `@libraries` module attribute below). The `:soot` package itself
  ships:

    * `Mix.Tasks.Soot.New` — `mix soot.new my_iot` to scaffold a new
      project with all libraries wired in.
    * `Mix.Tasks.Soot.Broker.GenConfig` — `mix soot.broker.gen_config`
      to render both Mosquitto and EMQX configs from the operator's
      MQTT-using resources.
    * `SCALING.md` — the scaling-cliff document.
    * Deployment runbook in `README.md`.

  Use `Soot.libraries/0` to enumerate the constituent libraries; useful
  for diagnostics and documentation generation.

  Each entry is keyed by the library's app name and carries:

    * `:module` — the library's top-level module, used by
      `extensions_loaded?/0` to probe whether it's compiled into this
      build.
    * `:role` — short human-readable description.
    * `:standalone?` — true for libraries that make sense outside the
      Soot framework (`ash_*` packages).
    * `:optional?` — true for libraries that are NOT pulled in as
      compile-time dependencies of `:soot` (today, just `ash_jwt`,
      which ships as a standalone opt-in escape hatch when an
      operator wants JWT-bearer auth instead of mTLS). Optional
      entries are skipped by `extensions_loaded?/0`.
  """

  @libraries %{
    ash_pki: %{module: AshPki, role: "PKI primitives", standalone?: true},
    ash_mqtt: %{module: AshMqtt, role: "MQTT as Ash transport", standalone?: true},
    ash_jwt: %{
      module: AshJwt,
      role: "JWT bearer-token plug",
      standalone?: true,
      optional?: true
    },
    soot_core: %{module: SootCore, role: "Tenants, devices, batches, enrollment"},
    soot_telemetry: %{module: SootTelemetry, role: "Telemetry streams + ingest"},
    soot_segments: %{module: SootSegments, role: "Materialized rollups"},
    soot_contracts: %{module: SootContracts, role: "Device-facing contract bundles"},
    soot_admin: %{module: SootAdmin, role: "Cinder admin building blocks"}
  }

  @doc "Return the constituent libraries with their roles."
  @spec libraries() :: %{atom() => map()}
  def libraries, do: @libraries

  @doc """
  Are the (non-optional) constituent libraries all loaded?

  Skips entries flagged `optional?: true` — those are not compile-time
  dependencies of `:soot` and aren't expected to be loaded.
  """
  @spec extensions_loaded?() :: boolean()
  def extensions_loaded? do
    @libraries
    |> Enum.reject(fn {_, meta} -> Map.get(meta, :optional?, false) end)
    |> Enum.all?(fn {_, %{module: m}} -> Code.ensure_loaded?(m) end)
  end
end
