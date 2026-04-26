defmodule Soot.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/lawik/soot"

  def project do
    [
      app: :soot,
      version: @version,
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :eex],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts",
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters?: true
      ]
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
      files: ~w(lib priv .formatter.exs mix.exs README.md SPEC.md SCALING.md LICENSE* CHANGELOG*),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "SPEC.md", "SCALING.md"]
    ]
  end

  defp aliases do
    [
      format: "format --migrate",
      credo: "credo --strict"
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
      {:igniter, "~> 0.6", optional: true},
      {:jason, "~> 1.4"},

      # Dev / test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end
end
