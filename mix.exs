defmodule Soot.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :soot,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "Meta package for the Soot IoT framework: project generator, broker config wrapper, deployment docs."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README.md SPEC.md SCALING.md),
      links: %{}
    ]
  end

  defp deps do
    [
      {:ash_pki, path: "../ash_pki"},
      {:ash_mqtt, path: "../ash_mqtt"},
      {:soot_core, path: "../soot_core"},
      {:soot_telemetry, path: "../soot_telemetry"},
      {:soot_segments, path: "../soot_segments"},
      {:soot_contracts, path: "../soot_contracts"},
      {:soot_admin, path: "../soot_admin"},
      {:jason, "~> 1.4"}
    ]
  end
end
