defmodule Soot do
  @moduledoc """
  Soot — IoT framework on Ash.

  This module is the umbrella entry point. The framework's
  functionality lives in the constituent libraries (`ash_pki`,
  `ash_mqtt`, `soot_core`, `soot_telemetry`, `soot_segments`,
  `soot_contracts`, `soot_admin`). The `:soot` package itself ships:

    * `Mix.Tasks.Soot.New` — `mix soot.new my_iot` to scaffold a new
      project with all libraries wired in.
    * `Mix.Tasks.Soot.Broker.GenConfig` — `mix soot.broker.gen_config`
      to render both Mosquitto and EMQX configs from the operator's
      MQTT-using resources.
    * `SCALING.md` — the scaling-cliff document.
    * Deployment runbook in `README.md`.

  Use `Soot.libraries/0` to enumerate the constituent libraries; useful
  for diagnostics and documentation generation.
  """

  @libraries %{
    ash_pki: %{module: AshPki, role: "PKI primitives", standalone?: true},
    ash_mqtt: %{module: AshMqtt, role: "MQTT as Ash transport", standalone?: true},
    ash_jwt: %{module: AshJwt, role: "JWT bearer-token plug", standalone?: true},
    soot_core: %{module: SootCore, role: "Tenants, devices, batches, enrollment"},
    soot_telemetry: %{module: SootTelemetry, role: "Telemetry streams + ingest"},
    soot_segments: %{module: SootSegments, role: "Materialized rollups"},
    soot_contracts: %{module: SootContracts, role: "Device-facing contract bundles"},
    soot_admin: %{module: SootAdmin, role: "Cinder admin building blocks"}
  }

  @doc "Return the constituent libraries with their roles."
  @spec libraries() :: %{atom() => map()}
  def libraries, do: @libraries

  @doc "Are the standalone Ash extensions all loaded?"
  @spec extensions_loaded?() :: boolean()
  def extensions_loaded? do
    Enum.all?(@libraries, fn {_, %{module: m}} -> Code.ensure_loaded?(m) end)
  end
end
