defmodule Mix.Tasks.Soot.Seed do
  @shortdoc "Plant a default tenant + admin user (and optionally a demo fleet)"

  @moduledoc """
  Seeds an operator's freshly-installed Soot project so the admin UI
  has a working actor + tenant on first boot.

      mix soot.seed              # default tenant + admin user
      mix soot.seed --demo       # additionally plant a 5-device fleet
                                 # under the default tenant

  Intended for development. Do NOT run in production — it creates a
  predictable admin password (override with `--admin-password`).

  ## What it always creates

    * `SootCore.Tenant` slug: `default`, name: `Default`
    * Admin `<App>.Accounts.User` with `role: :admin` and
      `tenant_id` pointing at the default tenant. Email + password
      are printed at the end of the run.

  ## What `--demo` adds

    * `SootCore.SerialScheme` `DEMO-` prefix on the default tenant
    * `SootCore.ProductionBatch` `demo-batch-1`
    * 5 unprovisioned `SootCore.Device` rows under that batch
    * Per-device `SootCore.DeviceShadow` with desired state
      `{weather_enabled: true, weather_interval_s: 60, label: "lab-N"}`
    * Registers `MyApp.Telemetry.{Cpu,Memory,Disk,OutdoorTemperature}`
      stream modules via `SootTelemetry.Registry.register_all/1`

  ## Options

    * `--demo` — also plant the demo fleet described above.
    * `--simulator` — only meaningful with `--demo`. Pulses log lines
      on a few seconds' interval to mimic a running fleet. Press
      Ctrl+C to stop.
    * `--admin-email` — email for the seeded admin user. Default
      `admin@example.com`.
    * `--admin-password` — password. Default `changeme`. Printed
      to stdout regardless of source.
    * `--tenant-slug` — slug for the default tenant. Default
      `default`.
    * `--tenant-name` — name for the default tenant. Default
      `Default`.
    * `--batch-size` — only meaningful with `--demo`. How many
      devices in the batch. Default 5.
  """

  use Mix.Task

  @switches [
    demo: :boolean,
    simulator: :boolean,
    admin_email: :string,
    admin_password: :string,
    tenant_slug: :string,
    tenant_name: :string,
    batch_size: :integer
  ]

  @defaults [
    demo: false,
    simulator: false,
    admin_email: "admin@example.com",
    admin_password: "changeme",
    tenant_slug: "default",
    tenant_name: "Default",
    batch_size: 5
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    opts = Keyword.merge(@defaults, opts)

    Mix.Task.run("app.start")

    app_module = derive_app_module()

    Mix.shell().info("==> Soot seed starting (app: #{inspect(app_module)})\n")

    tenant = seed_tenant(opts[:tenant_slug], opts[:tenant_name])
    user = seed_admin_user(app_module, tenant, opts[:admin_email], opts[:admin_password])

    if opts[:demo] do
      scheme = seed_serial_scheme(tenant)
      batch = seed_batch(tenant, scheme)
      devices = seed_devices(tenant, scheme, batch, opts[:batch_size])
      _shadows = seed_shadows(devices)
      _streams = seed_telemetry_streams(app_module)

      Mix.shell().info("""

      ==> Soot seed complete (with demo fleet).

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
    else
      Mix.shell().info("""

      ==> Soot seed complete.

        Tenant:           #{tenant_label(tenant)}
        Admin sign-in:    #{opts[:admin_email]} / #{opts[:admin_password]}

      Visit http://localhost:4000/admin after `mix phx.server`.

      Pass `--demo` to additionally plant a 5-device fleet under the
      default tenant for a non-empty admin UI.
      """)

      _ = user
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

  # Every Ash call routes through the `:seed` System actor. The
  # default policies on the soot_core / ash_pki / soot_telemetry /
  # soot_segments / soot_contracts resources (POLICY-SPEC §4.1) accept
  # `:seed` alongside their per-resource service actors. This keeps
  # the bypass visible in the policy DSL — preferable to
  # `authorize?: false`, which `SootCore.Credo.NoAuthorizeFalse`
  # refuses outside `test/support/` (POLICY-SPEC §5, §7).
  defp ash_opts, do: [actor: SootCore.Actors.system(:seed)]

  defp seed_tenant(slug, name) do
    case SootCore.Tenant.create(slug, name, %{}, ash_opts()) do
      {:ok, tenant} ->
        Mix.shell().info("    create  Tenant '#{slug}'")
        tenant

      {:error, _} ->
        case SootCore.Tenant.get_by_slug(slug, ash_opts()) do
          {:ok, tenant} ->
            Mix.shell().info("    exists  Tenant '#{slug}'")
            tenant

          _ ->
            Mix.raise("Failed to create tenant '#{slug}'.")
        end
    end
  end

  defp seed_serial_scheme(tenant) do
    case SootCore.SerialScheme.create(tenant.id, "demo-scheme", "DEMO-", %{}, ash_opts()) do
      {:ok, scheme} ->
        Mix.shell().info("    create  SerialScheme 'DEMO-'")
        scheme

      {:error, _} ->
        case SootCore.SerialScheme.for_tenant(tenant.id, ash_opts()) do
          {:ok, [scheme | _]} ->
            Mix.shell().info("    exists  SerialScheme 'DEMO-'")
            scheme

          _ ->
            Mix.raise("Failed to create demo serial scheme.")
        end
    end
  end

  defp seed_batch(tenant, scheme) do
    case SootCore.ProductionBatch.create(tenant.id, scheme.id, "demo-batch-1", %{}, ash_opts()) do
      {:ok, batch} ->
        Mix.shell().info("    create  ProductionBatch 'demo-batch-1'")
        batch

      {:error, _} ->
        case SootCore.ProductionBatch.for_tenant(tenant.id, ash_opts()) do
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

      find_or_create(
        fn -> SootCore.Device.create_unprovisioned(tenant.id, serial, %{}, ash_opts()) end,
        fn -> SootCore.Device.get_by_serial(tenant.id, serial, ash_opts()) end,
        "Device #{serial}"
      )
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
        find_or_create(
          fn -> SootCore.DeviceShadow.create(device.id, %{}, ash_opts()) end,
          fn -> SootCore.DeviceShadow.for_device(device.id, ash_opts()) end,
          "Shadow for device #{device.id}",
          quiet: true
        )

      case SootCore.DeviceShadow.update_desired(shadow, desired, ash_opts()) do
        {:ok, _updated} ->
          Mix.shell().info("    shadow  device #{device.serial} desired=#{inspect(desired)}")
          shadow

        {:error, _} ->
          Mix.shell().info("    skip    shadow update for #{device.serial}")
          shadow
      end
    end
  end

  defp seed_admin_user(app_module, tenant, email, password) do
    resource = Module.concat([app_module, "Accounts", "User"])

    if Code.ensure_loaded?(resource) do
      register_admin_user(resource, tenant, email, password)
    else
      Mix.shell().info(
        "    skip    Admin user (#{inspect(resource)} not present — run ash_authentication.install first)"
      )

      :skipped
    end
  end

  defp register_admin_user(resource, tenant, email, password) do
    attrs = %{
      email: email,
      password: password,
      password_confirmation: password,
      role: :admin,
      tenant_id: tenant.id
    }

    case call_register(resource, attrs) do
      {:ok, user} ->
        Mix.shell().info("    create  Admin user #{email} (role: :admin, tenant: #{tenant.id})")
        user

      {:error, _} ->
        find_existing_admin_user(resource, email)
    end
  end

  defp find_existing_admin_user(resource, email) do
    case lookup_existing(resource, email: email) do
      {:ok, user} ->
        Mix.shell().info("    exists  Admin user #{email}")
        user

      _ ->
        Mix.shell().info("    skip    Admin user (registration unavailable)")
        :skipped
    end
  end

  # Tries `create_fun.()` first, falls back to `find_fun.()` on
  # `{:error, _}`. Logs a "create" / "exists" line keyed on `label`
  # (suppress with `quiet: true`). Raises if neither path returns
  # `{:ok, _}`.
  defp find_or_create(create_fun, find_fun, label, opts \\ []) do
    quiet? = Keyword.get(opts, :quiet, false)

    case create_fun.() do
      {:ok, value} ->
        if !quiet?, do: Mix.shell().info("    create  #{label}")
        value

      {:error, _} ->
        find_existing!(find_fun, label, quiet?)
    end
  end

  defp find_existing!(find_fun, label, quiet?) do
    case find_fun.() do
      {:ok, value} ->
        if !quiet?, do: Mix.shell().info("    exists  #{label}")
        value

      _ ->
        Mix.raise("Failed to create #{label}.")
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

      Mix.shell().info(
        "    simulator  tick (real device sim lands once soot_nerves_example is wired up)"
      )
    end)
    |> Enum.each(& &1)
  end

  defp call_register(resource, attrs) do
    cond do
      function_exported?(resource, :register_with_password, 2) ->
        resource.register_with_password(attrs, ash_opts())

      function_exported?(resource, :register_with_password, 1) ->
        resource.register_with_password(attrs)

      function_exported?(resource, :create, 2) ->
        resource.create(attrs, ash_opts())

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
    |> Ash.read_one(ash_opts())
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
