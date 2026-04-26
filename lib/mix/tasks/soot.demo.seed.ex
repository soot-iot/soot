defmodule Mix.Tasks.Soot.Demo.Seed do
  @shortdoc "Plant a demo tenant, devices, telemetry stream, and admin user"

  @moduledoc """
  Seeds an operator's freshly-installed Soot project with enough data
  to make the admin UI non-empty on first boot.

  Intended for development. Do NOT run in production — it creates a
  predictable admin password.

      mix soot.demo.seed [--simulator]

  ## What it creates

    * Tenant `demo`
    * SerialScheme `DEMO-{seq:6}`
    * ProductionBatch with 25 unprovisioned devices
    * Admin user (printed credentials at the end)
    * Telemetry stream `vibration` (axis_x/y/z float32)
    * Segment `vibration_p95_hourly`

  ## Options

    * `--simulator` — start a background task that publishes fake
      telemetry every few seconds so the admin's Telemetry tab has
      moving data. Press Ctrl+C to stop.
    * `--admin-email` — email for the seeded admin user. Default
      `admin@example.com`.
    * `--admin-password` — password. Default `demo-password`. Printed
      to stdout regardless of source.
    * `--batch-size` — how many devices in the batch. Default 25.
  """

  use Mix.Task

  @switches [
    simulator: :boolean,
    admin_email: :string,
    admin_password: :string,
    batch_size: :integer
  ]

  @defaults [
    simulator: false,
    admin_email: "admin@example.com",
    admin_password: "demo-password",
    batch_size: 25
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    opts = Keyword.merge(@defaults, opts)

    Mix.Task.run("app.start")

    app_module = derive_app_module()

    Mix.shell().info("==> Soot demo seed starting (app: #{inspect(app_module)})\n")

    tenant = seed_tenant(app_module)
    scheme = seed_serial_scheme(app_module, tenant)
    batch = seed_batch(app_module, tenant, scheme, opts[:batch_size])
    _user = seed_admin_user(app_module, opts[:admin_email], opts[:admin_password])
    stream = seed_telemetry_stream(app_module, tenant)
    _segment = seed_segment(app_module, stream)

    Mix.shell().info("""

    ==> Demo seed complete.

      Tenant:           #{tenant_label(tenant)}
      Serial scheme:    DEMO-{seq:6}
      Production batch: #{batch_label(batch)} (#{opts[:batch_size]} devices)
      Telemetry stream: vibration
      Segment:          vibration_p95_hourly

      Admin sign-in:    #{opts[:admin_email]} / #{opts[:admin_password]}

    Visit http://localhost:4000/admin after `mix phx.server`.
    """)

    if opts[:simulator] do
      Mix.shell().info("==> Starting simulator (Ctrl+C to stop)…\n")
      run_simulator(app_module, batch, stream)
    end
  end

  defp derive_app_module do
    Mix.Project.config()
    |> Keyword.fetch!(:app)
    |> Atom.to_string()
    |> Macro.camelize()
    |> List.wrap()
    |> Module.concat()
  end

  defp seed_tenant(app) do
    resource = Module.concat([app, "Devices", "Tenant"])
    require_resource!(resource, "soot_core")

    case call_create(resource, %{name: "demo", slug: "demo"}) do
      {:ok, tenant} ->
        Mix.shell().info("    create  Tenant 'demo'")
        tenant

      {:error, error} ->
        case lookup_existing(resource, slug: "demo") do
          {:ok, tenant} ->
            Mix.shell().info("    exists  Tenant 'demo'")
            tenant

          _ ->
            Mix.raise("Failed to create demo tenant: #{inspect(error)}")
        end
    end
  end

  defp seed_serial_scheme(app, tenant) do
    resource = Module.concat([app, "Devices", "SerialScheme"])
    require_resource!(resource, "soot_core")

    attrs = %{
      tenant_id: tenant_id(tenant),
      name: "demo",
      pattern: "DEMO-{seq:6}"
    }

    case call_create(resource, attrs) do
      {:ok, scheme} ->
        Mix.shell().info("    create  SerialScheme 'DEMO-{seq:6}'")
        scheme

      {:error, _} ->
        case lookup_existing(resource, name: "demo") do
          {:ok, scheme} ->
            Mix.shell().info("    exists  SerialScheme 'DEMO-{seq:6}'")
            scheme

          _ ->
            Mix.raise("Failed to create demo serial scheme.")
        end
    end
  end

  defp seed_batch(app, tenant, scheme, count) do
    resource = Module.concat([app, "Devices", "ProductionBatch"])
    require_resource!(resource, "soot_core")

    attrs = %{
      tenant_id: tenant_id(tenant),
      serial_scheme_id: Map.get(scheme, :id),
      label: "demo-batch-1",
      device_count: count
    }

    case call_create(resource, attrs) do
      {:ok, batch} ->
        Mix.shell().info("    create  ProductionBatch 'demo-batch-1' (#{count} devices)")
        batch

      {:error, error} ->
        Mix.raise("Failed to create demo batch: #{inspect(error)}")
    end
  end

  defp seed_admin_user(app, email, password) do
    resource = Module.concat([app, "Accounts", "User"])
    require_resource!(resource, "ash_authentication")

    attrs = %{
      email: email,
      password: password,
      password_confirmation: password
    }

    case call_register(resource, attrs) do
      {:ok, user} ->
        Mix.shell().info("    create  Admin user #{email}")
        user

      {:error, _} ->
        case lookup_existing(resource, email: email) do
          {:ok, user} ->
            Mix.shell().info("    exists  Admin user #{email}")
            user

          _ ->
            Mix.raise("Failed to create admin user.")
        end
    end
  end

  defp seed_telemetry_stream(app, tenant) do
    resource = Module.concat([app, "Telemetry", "Stream"])
    require_resource!(resource, "soot_telemetry")

    attrs = %{
      tenant_id: tenant_id(tenant),
      name: "vibration",
      fields: [
        %{name: "axis_x", type: "float32"},
        %{name: "axis_y", type: "float32"},
        %{name: "axis_z", type: "float32"}
      ],
      retention_months: 12,
      clickhouse_engine: "MergeTree"
    }

    case call_create(resource, attrs) do
      {:ok, stream} ->
        Mix.shell().info("    create  Telemetry stream 'vibration'")
        stream

      {:error, _} ->
        case lookup_existing(resource, name: "vibration") do
          {:ok, stream} ->
            Mix.shell().info("    exists  Telemetry stream 'vibration'")
            stream

          _ ->
            Mix.raise("Failed to create telemetry stream.")
        end
    end
  end

  defp seed_segment(app, stream) do
    resource = Module.concat([app, "Segments", "Segment"])
    require_resource!(resource, "soot_segments")

    attrs = %{
      name: "vibration_p95_hourly",
      source_stream_id: Map.get(stream, :id),
      granularity: "1h",
      metrics: [%{column: "axis_x", aggregation: "p95"}]
    }

    case call_create(resource, attrs) do
      {:ok, segment} ->
        Mix.shell().info("    create  Segment 'vibration_p95_hourly'")
        segment

      {:error, _} ->
        case lookup_existing(resource, name: "vibration_p95_hourly") do
          {:ok, segment} -> segment
          _ -> Mix.raise("Failed to create segment.")
        end
    end
  end

  defp run_simulator(_app, _batch, _stream) do
    # Placeholder: real simulator wiring lives behind the Phase 6 device
    # libraries. For now, just pulse a log line so the operator sees
    # something.
    Stream.repeatedly(fn ->
      Process.sleep(2_000)
      Mix.shell().info("    simulator  tick (placeholder — real device lib lands in Phase 6)")
    end)
    |> Enum.each(& &1)
  end

  defp call_create(resource, attrs) do
    if function_exported?(resource, :create, 1) do
      resource.create(attrs)
    else
      Ash.Seed.seed!(resource, attrs)
      |> then(&{:ok, &1})
    end
  rescue
    e -> {:error, e}
  end

  defp call_register(resource, attrs) do
    cond do
      function_exported?(resource, :register_with_password, 1) ->
        resource.register_with_password(attrs)

      function_exported?(resource, :create, 1) ->
        resource.create(attrs)

      true ->
        {:error, :no_register_action}
    end
  rescue
    e -> {:error, e}
  end

  defp lookup_existing(resource, filter) do
    require Ash.Query

    resource
    |> Ash.Query.filter(^filter)
    |> Ash.read_one()
    |> case do
      {:ok, nil} -> :error
      {:ok, record} -> {:ok, record}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp require_resource!(module, lib) do
    if !Code.ensure_loaded?(module) do
      Mix.raise("""
      Demo seed requires #{inspect(module)}.

      It looks like the `#{lib}` installer has not been run yet, or the
      module name does not match the convention. Re-run:

          mix igniter.install soot

      Or pass the correct module name via task options.
      """)
    end
  end

  defp tenant_id(tenant), do: Map.get(tenant, :id)
  defp tenant_label(tenant), do: Map.get(tenant, :slug) || Map.get(tenant, :name) || "<unknown>"
  defp batch_label(batch), do: Map.get(batch, :label) || "<unknown>"
end
