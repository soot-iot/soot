defmodule Mix.Tasks.Soot.Install.Docs do
  @moduledoc false

  def short_doc do
    "Installs the Soot IoT framework into a Phoenix project"
  end

  def example do
    "mix igniter.install soot"
  end

  def long_doc do
    """
    #{short_doc()}

    Composes every per-library installer in dependency order and
    mounts the device-facing endpoints in the operator's router. See
    `UI-SPEC.md` in the `soot` package for the full design.

    ## Canonical bootstrap (from a clean machine)

    ```bash
    mix archive.install hex igniter_new
    mix archive.install hex phx_new
    mix igniter.new my_iot \\
        --install soot \\
        --with phx.new \\
        --with-args="--no-mailer --database postgres"
    cd my_iot
    mix ash.setup
    mix soot.demo.seed   # optional
    mix phx.server
    ```

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--example` / `--no-example` — when set (default: ON), each
      child installer runs with `--example` so the generated project
      is populated with illustrative resources (outdoor temperature
      stream, weather shadow), and `mix soot.demo.seed` is scheduled
      to run after `ash.setup`. Pass `--no-example` for a clean
      skeleton.
    * `--yes` — answer "yes" to dependency-fetching prompts
      (passed through to child installers).
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Soot.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    # The order matters: each child relies on resources / config the
    # earlier ones produced. Mirrors UI-SPEC §4.
    @child_installers [
      "ash.install",
      "ash_postgres.install",
      "ash_phoenix.install",
      "ash_authentication.install",
      "ash_authentication_phoenix.install",
      "ash_pki.install",
      "soot_core.install",
      "ash_mqtt.install",
      "soot_telemetry.install",
      "soot_segments.install",
      "soot_contracts.install",
      "soot_admin.install"
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :soot,
        example: __MODULE__.Docs.example(),
        only: nil,
        composes: @child_installers,
        schema: [
          example: :boolean,
          yes: :boolean
        ],
        defaults: [example: true, yes: false],
        aliases: [y: :yes, e: :example]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options
      child_argv = build_child_argv(igniter.args.argv, options)

      igniter
      |> compose_children(child_argv)
      |> generate_example_shadow(options)
      |> mount_device_pipeline()
      |> patch_broker_runtime_config()
      |> note_next_steps(options)
    end

    # `--example` defaults to true at the umbrella level. When it is
    # set, make sure children that read `igniter.args.options[:example]`
    # see it explicitly in argv (their own defaults are false). When
    # the operator passed `--no-example`, leave argv alone.
    defp build_child_argv(argv, options) do
      cond do
        "--example" in argv or "-e" in argv -> argv
        "--no-example" in argv -> argv
        options[:example] -> argv ++ ["--example"]
        true -> argv
      end
    end

    defp compose_children(igniter, argv) do
      Enum.reduce(@child_installers, igniter, fn task, igniter ->
        if task_available?(task) do
          Igniter.compose_task(igniter, task, argv)
        else
          Igniter.add_warning(igniter, """
          Skipping `mix #{task}` — the task is not available.

          This usually means the corresponding library has not yet
          published an installer. Re-run `mix igniter.install soot`
          once the library is updated, or run the installer manually.
          """)
        end
      end)
    end

    defp task_available?(task) do
      Mix.Task.get(task) != nil
    end

    # When `--example` is set, generate the example device shadow
    # resource in the operator's project. Demonstrates the three
    # shadow patterns — boolean toggle, integer tunable, free-form
    # label — that the device-side example consumes.
    #
    # `AshMqtt.Shadow` is an `Ash.Resource` extension; the shadow
    # declaration lives on a resource that owns the shadow attributes.
    defp generate_example_shadow(igniter, options) do
      if options[:example] do
        web_app = Igniter.Project.Application.app_name(igniter)
        module = Igniter.Project.Module.module_name(igniter, "Devices.DeviceShadow")

        {exists?, igniter} = Igniter.Project.Module.module_exists(igniter, module)

        if exists? do
          igniter
        else
          Igniter.Project.Module.create_module(
            igniter,
            module,
            ~s'''
            @moduledoc """
            Per-device shadow resource demonstrating three shadow
            patterns:

              * `:weather_enabled` — boolean toggle (binary control)
              * `:weather_interval_s` — integer tunable (numeric setting)
              * `:label` — free-form string (operator-set metadata)

            Generated by `mix soot.install --example`. Operators own
            this file post-install; the framework does not re-touch it.

            Declared under `SootCore.Domain` (the registered framework
            domain) with `validate_domain_inclusion?: false` because
            the resource is operator-owned, not part of `SootCore.Domain`'s
            `resources` block. Move it under your own domain by
            replacing the `domain:` option once you have one.

            See `SootCore.DeviceShadow` for the durable backing store
            (desired/reported maps, version, last_reported_at).
            """

            use Ash.Resource,
              otp_app: :#{web_app},
              domain: SootCore.Domain,
              validate_domain_inclusion?: false,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshMqtt.Shadow]

            attributes do
              uuid_primary_key :id

              attribute :weather_enabled, :boolean,
                default: true,
                public?: true,
                description: "If false, device pauses outdoor_temperature publishing."
              attribute :weather_interval_s, :integer,
                default: 60,
                public?: true,
                description: "Seconds between outdoor_temperature samples."
              attribute :label, :string,
                public?: true,
                description: "Free-form operator-set label. Echoed in reported state."
              attribute :firmware_version, :string, public?: true
              attribute :uptime_s, :integer, public?: true
            end

            actions do
              defaults [:read, :destroy, :create, :update]
            end

            mqtt_shadow do
              base "tenants/:tenant_id/devices/:device_id/shadow"
              as :device_shadow
              qos 1
              retain true
              payload_format :json
              acl :tenant_isolated

              desired_attributes [:weather_enabled, :weather_interval_s, :label]
              reported_attributes [
                :weather_enabled,
                :weather_interval_s,
                :label,
                :firmware_version,
                :uptime_s
              ]
            end
            '''
          )
        end
      else
        igniter
      end
    end

    defp mount_device_pipeline(igniter) do
      {igniter, router} =
        Igniter.Libs.Phoenix.select_router(
          igniter,
          "Which Phoenix router should the Soot device-facing endpoints be mounted in?"
        )

      if router do
        igniter
        |> add_device_mtls_pipeline(router)
        |> add_device_scope(router)
      else
        Igniter.add_warning(igniter, """
        No Phoenix router found. The device-facing endpoints
        (/enroll, /ingest, /.well-known/soot/contract) were not
        mounted. Set up a Phoenix router and re-run
        `mix igniter.install soot`.
        """)
      end
    end

    defp add_device_mtls_pipeline(igniter, router) do
      {igniter, has_pipeline?} =
        Igniter.Libs.Phoenix.has_pipeline(igniter, router, :device_mtls)

      if has_pipeline? do
        igniter
      else
        Igniter.Libs.Phoenix.add_pipeline(
          igniter,
          :device_mtls,
          "plug AshPki.Plug.MTLS, require_known_certificate: true",
          router: router
        )
      end
    end

    defp add_device_scope(igniter, router) do
      if device_scope_present?(igniter, router) do
        igniter
      else
        Igniter.Libs.Phoenix.add_scope(
          igniter,
          "/",
          """
          pipe_through :device_mtls

          forward "/enroll", SootCore.Plug.Enroll
          forward "/ingest", SootTelemetry.Plug.Ingest
          forward "/.well-known/soot/contract", SootContracts.Plug.WellKnown
          """,
          router: router
        )
      end
    end

    # The device scope is uniquely identifiable by the SootCore.Plug.Enroll
    # forward. If we already see it in the router, the scope is mounted.
    defp device_scope_present?(igniter, router) do
      {_, _source, zipper} = Igniter.Project.Module.find_module!(igniter, router)

      case Igniter.Code.Common.move_to(zipper, fn z ->
             Igniter.Code.Function.function_call?(z, :forward, 2) and
               Igniter.Code.Function.argument_equals?(z, 1, SootCore.Plug.Enroll)
           end) do
        {:ok, _} -> true
        :error -> false
      end
    end

    # Patches `config/runtime.exs` with the operator's broker
    # connection settings, all driven from env so the same release
    # can roll across environments without recompilation. Defaults
    # match the dev/test layout that `mix ash_pki.init --out priv/pki`
    # produces and a local EMQX listening on 8883 with mTLS.
    defp patch_broker_runtime_config(igniter) do
      igniter
      |> set_runtime_env(:ash_mqtt, [:broker_url], "ssl://localhost:8883", "SOOT_BROKER_URL")
      |> set_runtime_env(:ash_mqtt, [:ca_path], "priv/pki/trust_bundle.pem", "SOOT_BROKER_CA")
      |> set_runtime_env(
        :ash_mqtt,
        [:cert_path],
        "priv/pki/server_chain.pem",
        "SOOT_BROKER_CERT"
      )
      |> set_runtime_env(:ash_mqtt, [:key_path], "priv/pki/server_key.pem", "SOOT_BROKER_KEY")
    end

    defp set_runtime_env(igniter, app, key_path, default, env_var) do
      Igniter.Project.Config.configure(
        igniter,
        "runtime.exs",
        app,
        key_path,
        {:code, Sourceror.parse_string!(~s|System.get_env("#{env_var}", "#{default}")|)}
      )
    end

    defp note_next_steps(igniter, options) do
      example_lines =
        if options[:example] do
          """

          Example resources were planted (--example, default ON):

            * lib/<app>/telemetry/outdoor_temperature.ex   sensor stream
            * lib/<app>/devices/device_shadow.ex           shadow resource
              (weather_enabled / weather_interval_s / label)

          `mix soot.demo.seed` will run after `mix ash.setup` to
          create the demo tenant, an admin user, and 5 :operational
          devices with pre-populated shadow desired state.

          Pass `--no-example` to skip the example resources and the
          demo seed.
          """
        else
          ""
        end

      igniter =
        Igniter.add_notice(igniter, """
        Soot installed.
        #{example_lines}
        Next steps:

          mix ash.setup           # apply migrations + extension setup
          mix phx.server

        Device-facing endpoints are mounted under the :device_mtls
        pipeline in your router. Admin LiveViews are at /admin.

        Broker connection (in config/runtime.exs) reads from env:
          SOOT_BROKER_URL    default ssl://localhost:8883
          SOOT_BROKER_CA     default priv/pki/trust_bundle.pem
          SOOT_BROKER_CERT   default priv/pki/server_chain.pem
          SOOT_BROKER_KEY    default priv/pki/server_key.pem

        After `mix soot.broker.gen_config`, push the rendered EMQX
        bundle with:

          mix soot.broker.push_emqx --url http://localhost:18083 \\
              --api-key $EMQX_API_KEY --api-secret $EMQX_API_SECRET
        """)

      if options[:example] do
        Igniter.delay_task(igniter, "soot.demo.seed")
      else
        igniter
      end
    end
  end
else
  defmodule Mix.Tasks.Soot.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task `soot.install` requires igniter. Add `{:igniter, "~> 0.6"}`
      to your project deps and try again, or invoke via:

          mix igniter.install soot

      For more information, see https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
