defmodule Mix.Tasks.Soot.Demo.Seed do
  @shortdoc "Plant a demo tenant, devices, telemetry stream, and admin user"

  @moduledoc """
  Seeds an operator's freshly-installed Soot project with enough data
  to make the admin UI non-empty on first boot.

  Intended for development. Do NOT run in production — it creates a
  predictable admin password.

      mix soot.demo.seed [--simulator]

  ## What it creates

    * `SootCore.Tenant` slug: `demo`
    * `SootCore.SerialScheme` `DEMO-` prefix
    * `SootCore.ProductionBatch` `demo-batch-1`
    * 5 unprovisioned `SootCore.Device` rows under that batch
    * Per-device `SootCore.DeviceShadow` with desired state
      `{weather_enabled: true, weather_interval_s: 60, label: "lab-N"}`
    * Admin `<App>.Accounts.User` (printed credentials at the end)
    * Registers `MyApp.Telemetry.{Cpu,Memory,Disk,OutdoorTemperature}`
      stream modules via `SootTelemetry.Registry.register_all/1`

  ## Options

    * `--simulator` — pulse log lines on a few seconds' interval to
      mimic a running fleet. Press Ctrl+C to stop. (Real telemetry
      simulation lands once the device-side example is wired up.)
    * `--admin-email` — email for the seeded admin user. Default
      `admin@example.com`.
    * `--admin-password` — password. Default `demo-password`. Printed
      to stdout regardless of source.
    * `--batch-size` — how many devices in the batch. Default 5.
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
    batch_size: 5
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    opts = Keyword.merge(@defaults, opts)

    Mix.Task.run("app.start")

    app_module = derive_app_module()

    Mix.shell().info("==> Soot demo seed starting (app: #{inspect(app_module)})\n")

    tenant = seed_tenant()
    scheme = seed_serial_scheme(tenant)
    batch = seed_batch(tenant, scheme)
    devices = seed_devices(tenant, scheme, batch, opts[:batch_size])
    _shadows = seed_shadows(devices)
    _user = seed_admin_user(app_module, opts[:admin_email], opts[:admin_password])
    _streams = seed_telemetry_streams(app_module)

    Mix.shell().info("""

    ==> Demo seed complete.

      Tenant:           #{tenant_label(tenant)}
      Serial scheme:    DEMO- (#{tenant_label(tenant)})
      Production batch: #{batch_label(batch)} (#{opts[:batch_size]} unprovisioned devices)
      Telemetry streams: cpu, memory, disk, outdoor_temperature
      Shadow desired:   weather_enabled=true, weather_interval_s=60, label="lab-N"

      Admin sign-in:    #{opts[:admin_email]} / #{opts[:admin_password]}

    Visit http://localhost:4000/admin after `mix phx.server`.

    Devices land in :unprovisioned. Once the device-side example
    bootstraps + enrolls, they advance through the state machine to
    :operational on their own.
    """)

    if opts[:simulator] do
      Mix.shell().info("==> Starting simulator (Ctrl+C to stop)…\n")
      run_simulator()
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

  defp seed_tenant do
    case SootCore.Tenant.create("demo", "Demo Tenant") do
      {:ok, tenant} ->
        Mix.shell().info("    create  Tenant 'demo'")
        tenant

      {:error, _} ->
        case SootCore.Tenant.get_by_slug("demo") do
          {:ok, tenant} ->
            Mix.shell().info("    exists  Tenant 'demo'")
            tenant

          _ ->
            Mix.raise("Failed to create demo tenant.")
        end
    end
  end

  defp seed_serial_scheme(tenant) do
    case SootCore.SerialScheme.create(tenant.id, "demo-scheme", "DEMO-") do
      {:ok, scheme} ->
        Mix.shell().info("    create  SerialScheme 'DEMO-'")
        scheme

      {:error, _} ->
        case SootCore.SerialScheme.for_tenant(tenant.id) do
          {:ok, [scheme | _]} ->
            Mix.shell().info("    exists  SerialScheme 'DEMO-'")
            scheme

          _ ->
            Mix.raise("Failed to create demo serial scheme.")
        end
    end
  end

  defp seed_batch(tenant, scheme) do
    case SootCore.ProductionBatch.create(tenant.id, scheme.id, "demo-batch-1") do
      {:ok, batch} ->
        Mix.shell().info("    create  ProductionBatch 'demo-batch-1'")
        batch

      {:error, _} ->
        case SootCore.ProductionBatch.for_tenant(tenant.id) do
          {:ok, [batch | _]} ->
            Mix.shell().info("    exists  ProductionBatch 'demo-batch-1'")
            batch

          _ ->
            Mix.raise("Failed to create demo batch.")
        end
    end
  end

  defp seed_devices(tenant, _scheme, _batch, count) do
    for i <- 1..count do
      serial = "DEMO-#{String.pad_leading(Integer.to_string(i), 4, "0")}"

      case SootCore.Device.create_unprovisioned(tenant.id, serial) do
        {:ok, device} ->
          Mix.shell().info("    create  Device #{serial}")
          device

        {:error, _} ->
          case SootCore.Device.get_by_serial(tenant.id, serial) do
            {:ok, device} ->
              Mix.shell().info("    exists  Device #{serial}")
              device

            _ ->
              Mix.raise("Failed to create device #{serial}.")
          end
      end
    end
  end

  defp seed_shadows(devices) do
    for {device, idx} <- Enum.with_index(devices, 1) do
      desired = %{
        "weather_enabled" => true,
        "weather_interval_s" => 60,
        "label" => "lab-#{idx}"
      }

      shadow =
        case SootCore.DeviceShadow.create(device.id) do
          {:ok, shadow} -> shadow
          {:error, _} ->
            case SootCore.DeviceShadow.for_device(device.id) do
              {:ok, shadow} -> shadow
              _ -> Mix.raise("Failed to create shadow for device #{device.id}.")
            end
        end

      case SootCore.DeviceShadow.update_desired(shadow, desired) do
        {:ok, _updated} ->
          Mix.shell().info("    shadow  device #{device.serial} desired=#{inspect(desired)}")
          shadow

        {:error, _} ->
          Mix.shell().info("    skip    shadow update for #{device.serial}")
          shadow
      end
    end
  end

  defp seed_admin_user(app_module, email, password) do
    resource = Module.concat([app_module, "Accounts", "User"])

    if !Code.ensure_loaded?(resource) do
      Mix.shell().info("    skip    Admin user (#{inspect(resource)} not present — run ash_authentication.install first)")
      :skipped
    else
      attrs = %{email: email, password: password, password_confirmation: password}

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
              Mix.shell().info("    skip    Admin user (registration unavailable)")
              :skipped
          end
      end
    end
  end

  defp seed_telemetry_streams(app_module) do
    candidates = [
      Module.concat([app_module, "Telemetry", "Cpu"]),
      Module.concat([app_module, "Telemetry", "Memory"]),
      Module.concat([app_module, "Telemetry", "Disk"]),
      Module.concat([app_module, "Telemetry", "OutdoorTemperature"])
    ]

    available = Enum.filter(candidates, &Code.ensure_loaded?/1)

    case SootTelemetry.Registry.register_all(available) do
      {:ok, results} ->
        for module <- available, do: Mix.shell().info("    register Stream #{inspect(module)}")
        results

      {:error, error} ->
        Mix.shell().info("    skip    telemetry stream registration: #{inspect(error)}")
        []
    end
  rescue
    e ->
      Mix.shell().info("    skip    telemetry stream registration: #{Exception.message(e)}")
      []
  end

  defp run_simulator do
    Stream.repeatedly(fn ->
      Process.sleep(2_000)
      Mix.shell().info("    simulator  tick (real device sim lands once soot_nerves_example is wired up)")
    end)
    |> Enum.each(& &1)
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

  defp tenant_label(tenant), do: Map.get(tenant, :slug) || Map.get(tenant, :name) || "<unknown>"
  defp batch_label(batch), do: Map.get(batch, :code) || "<unknown>"
end
