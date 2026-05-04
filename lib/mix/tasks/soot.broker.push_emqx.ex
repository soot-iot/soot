defmodule Mix.Tasks.Soot.Broker.PushEmqx do
  @shortdoc "Pushes the rendered EMQX rules + ACLs to a running broker"

  @moduledoc """
  Pushes an `emqx.json` bundle (as rendered by
  `mix soot.broker.gen_config`) to a running EMQX cluster's REST API.

      mix soot.broker.push_emqx \\
          --url http://localhost:18083 \\
          --api-key $EMQX_API_KEY \\
          --api-secret $EMQX_API_SECRET \\
          [--in priv/broker/emqx.json] \\
          [--dry-run]

  ## What gets pushed

  The bundle file is JSON of the shape:

      {
        "acl":   [...],
        "rules": [...]
      }

  This task:

    1. POSTs each entry in `acl` to `/api/v5/authorization/sources`
       (the file-source format EMQX expects for authorization).
    2. POSTs each entry in `rules` to `/api/v5/rules`.

  Failures are non-recoverable — the task exits non-zero and prints
  the broker's response. Use `--dry-run` to see what would be pushed
  without contacting the broker.

  ## Configuration

  Args > env vars > defaults. The recognised env vars are
  `EMQX_API_URL`, `EMQX_API_KEY`, `EMQX_API_SECRET`.
  `EMQX_API_URL` defaults to `http://localhost:18083`. The bundle
  path defaults to `priv/broker/emqx.json`.
  """

  use Mix.Task

  @switches [
    url: :string,
    api_key: :string,
    api_secret: :string,
    in: :string,
    dry_run: :boolean
  ]

  @aliases [u: :url, k: :api_key, s: :api_secret, i: :in]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)
    config = resolve_config(opts)
    bundle = read_bundle!(config.in_path)

    Mix.shell().info("==> Pushing #{config.in_path} to #{config.url}")

    if config.dry_run? do
      log_dry_run(bundle)
    else
      push_bundle!(config, bundle)
    end

    Mix.shell().info("==> Done.")
  end

  defp resolve_config(opts) do
    %{
      url: opts[:url] || System.get_env("EMQX_API_URL") || "http://localhost:18083",
      api_key:
        opts[:api_key] || System.get_env("EMQX_API_KEY") ||
          Mix.raise("missing --api-key (or EMQX_API_KEY env)"),
      api_secret:
        opts[:api_secret] || System.get_env("EMQX_API_SECRET") ||
          Mix.raise("missing --api-secret (or EMQX_API_SECRET env)"),
      in_path: opts[:in] || "priv/broker/emqx.json",
      dry_run?: opts[:dry_run] == true
    }
  end

  defp push_bundle!(config, bundle) do
    Application.ensure_all_started(:req)

    req =
      Req.new(
        base_url: config.url,
        auth: {:basic, "#{config.api_key}:#{config.api_secret}"},
        headers: [{"content-type", "application/json"}],
        retry: false,
        connect_options: [timeout: 10_000],
        receive_timeout: 30_000
      )

    :ok = push_acl(req, bundle["acl"] || [])
    :ok = push_rules(req, bundle["rules"] || [])
  end

  defp read_bundle!(path) do
    if !File.exists?(path) do
      Mix.raise("""
      EMQX bundle not found at #{path}.

      Run `mix soot.broker.gen_config --out priv/broker --resource …`
      first, or pass `--in <path>` if the bundle lives elsewhere.
      """)
    end

    case path |> File.read!() |> Jason.decode() do
      {:ok, %{} = bundle} ->
        bundle

      {:ok, other} ->
        Mix.raise("expected JSON object at #{path}, got #{inspect(other)}")

      {:error, error} ->
        Mix.raise("could not parse #{path} as JSON: #{Exception.message(error)}")
    end
  end

  defp push_acl(_req, []), do: :ok

  defp push_acl(req, acls) do
    Mix.shell().info("    push  #{length(acls)} ACL source(s)")

    Enum.each(acls, fn acl ->
      case Req.post(req, url: "/api/v5/authorization/sources", json: acl) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          Mix.raise("ACL push failed (status #{status}): #{inspect(body)}")

        {:error, reason} ->
          Mix.raise("ACL push transport error: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp push_rules(_req, []), do: :ok

  defp push_rules(req, rules) do
    Mix.shell().info("    push  #{length(rules)} rule(s)")

    Enum.each(rules, fn rule ->
      case Req.post(req, url: "/api/v5/rules", json: rule) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          Mix.raise("rule push failed (status #{status}): #{inspect(body)}")

        {:error, reason} ->
          Mix.raise("rule push transport error: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp log_dry_run(bundle) do
    acl_count = length(bundle["acl"] || [])
    rule_count = length(bundle["rules"] || [])

    Mix.shell().info("""
        DRY RUN — would push:
          #{acl_count} ACL source(s)
          #{rule_count} rule(s)
    """)
  end
end
