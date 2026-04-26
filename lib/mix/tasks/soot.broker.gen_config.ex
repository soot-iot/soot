defmodule Mix.Tasks.Soot.Broker.GenConfig do
  @shortdoc "Render Mosquitto + EMQX configs from MQTT-using resources"

  @moduledoc """
  Convenience wrapper that runs the per-broker generators in `ash_mqtt`
  for both Mosquitto and EMQX in a single command.

      mix soot.broker.gen_config \\
            --out priv/broker \\
            --resource MyApp.Device \\
            --resource MyApp.Device.Shadow \\
            [--mosquitto-only | --emqx-only] \\
            [--mosquitto-template priv/templates/mosquitto.conf.eex \\
             --ca-file priv/pki/trust_bundle.pem \\
             --cert-file priv/pki/server_chain.pem \\
             --key-file priv/pki/server_key.pem]

  Outputs (to `--out`):

    * `mosquitto.acl` — ACL file
    * `mosquitto.conf` — config file rendered from the bundled
      template (set the `--ca-file` / `--cert-file` / `--key-file`
      options to point at the trust material from `mix ash_pki.init`)
    * `emqx.json` — `{acl, rules}` bundle ready to push to EMQX's REST
      API

  Pass `--mosquitto-only` or `--emqx-only` to render just one set.
  """

  use Mix.Task

  @switches [
    out: :string,
    resource: [:string, :keep],
    mosquitto_only: :boolean,
    emqx_only: :boolean,
    mosquitto_template: :string,
    ca_file: :string,
    cert_file: :string,
    key_file: :string,
    persistence_dir: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _} = OptionParser.parse!(args, strict: @switches)

    out = Keyword.fetch!(opts, :out)
    resources = opts |> Keyword.get_values(:resource) |> Enum.map(&load_module/1)

    if resources == [] do
      Mix.raise("at least one --resource <module> is required")
    end

    only = mode(opts)

    File.mkdir_p!(out)

    cond do
      only in [:both, :mosquitto] -> render_mosquitto(resources, out, opts)
      true -> :skip
    end

    cond do
      only in [:both, :emqx] -> render_emqx(resources, out)
      true -> :skip
    end
  end

  defp mode(opts) do
    case {Keyword.get(opts, :mosquitto_only, false), Keyword.get(opts, :emqx_only, false)} do
      {true, true} -> Mix.raise("--mosquitto-only and --emqx-only are mutually exclusive")
      {true, _} -> :mosquitto
      {_, true} -> :emqx
      _ -> :both
    end
  end

  defp render_mosquitto(resources, out, opts) do
    acl_path = Path.join(out, "mosquitto.acl")
    File.write!(acl_path, AshMqtt.BrokerConfig.Mosquitto.render(resources))
    Mix.shell().info("    wrote #{acl_path}")

    {:ok, conf_path} = render_mosquitto_conf(resources, out, acl_path, opts)
    Mix.shell().info("    wrote #{conf_path}")
  end

  defp render_mosquitto_conf(_resources, out, acl_path, opts) do
    {template_path, source} = resolve_template(opts)

    if !File.exists?(template_path) do
      Mix.raise(template_missing_message(template_path, source))
    end

    bindings = [
      ca_file: Keyword.get(opts, :ca_file, "priv/pki/trust_bundle.pem"),
      cert_file: Keyword.get(opts, :cert_file, "priv/pki/server_chain.pem"),
      key_file: Keyword.get(opts, :key_file, "priv/pki/server_key.pem"),
      acl_file: acl_path,
      persistence_dir: Keyword.get(opts, :persistence_dir, "priv/broker/mosquitto-data")
    ]

    conf = EEx.eval_file(template_path, bindings)
    conf_path = Path.join(out, "mosquitto.conf")
    File.write!(conf_path, conf)
    {:ok, conf_path}
  end

  defp resolve_template(opts) do
    case Keyword.get(opts, :mosquitto_template) do
      nil ->
        bundled =
          :code.priv_dir(:soot)
          |> List.to_string()
          |> Path.join("templates/mosquitto.conf.eex")

        {bundled, :bundled}

      explicit ->
        {explicit, :explicit}
    end
  end

  defp template_missing_message(path, :explicit) do
    "mosquitto template not found at `#{path}` (passed via --mosquitto-template)"
  end

  defp template_missing_message(path, :bundled) do
    "bundled mosquitto template missing at `#{path}` — this should not happen; please file a bug"
  end

  defp render_emqx(resources, out) do
    json_path = Path.join(out, "emqx.json")
    File.write!(json_path, AshMqtt.BrokerConfig.EMQX.to_json(resources))
    Mix.shell().info("    wrote #{json_path}")
  end

  defp load_module(name) do
    mod = Module.concat([name])

    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        mod

      {:error, :nofile} ->
        Mix.raise("""
        could not load resource module `#{inspect(mod)}` — make sure it's
        compiled and reachable from this project (did you forget
        `MIX_ENV=test`?)
        """)

      {:error, reason} ->
        Mix.raise("could not load resource module `#{inspect(mod)}`: #{inspect(reason)}")
    end
  end
end
