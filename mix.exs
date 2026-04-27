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
      {:ash_pki, github: "soot-iot/ash_pki", branch: "main", override: true},
      {:ash_mqtt, github: "soot-iot/ash_mqtt", branch: "main", override: true},
      {:soot_core, github: "soot-iot/soot_core", branch: "main", override: true},
      {:soot_telemetry, github: "soot-iot/soot_telemetry", branch: "main", override: true},
      {:soot_segments, github: "soot-iot/soot_segments", branch: "main", override: true},
      {:soot_contracts, github: "soot-iot/soot_contracts", branch: "main", override: true},
      {:soot_admin, github: "soot-iot/soot_admin", branch: "main", override: true},
      {:igniter, "~> 0.6", optional: true},
      {:jason, "~> 1.4"},
      # `mix soot.broker.push_emqx` POSTs the rendered EMQX bundle
      # to a running broker's REST API.
      {:req, "~> 0.5"},

      # Dev / test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end
end
