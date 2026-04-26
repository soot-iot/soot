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

    * `--example` — runs each child installer with `--example` so the
      generated project is populated with illustrative resources, and
      schedules `mix soot.demo.seed` to run after `ash.setup`.
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
        defaults: [example: false, yes: false],
        aliases: [y: :yes, e: :example]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      argv = igniter.args.argv

      igniter
      |> compose_children(argv)
      |> mount_device_pipeline()
      |> note_next_steps(igniter.args.options)
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

    defp note_next_steps(igniter, options) do
      igniter =
        Igniter.add_notice(igniter, """
        Soot installed.

        Next steps:

          mix ash.setup           # apply migrations + extension setup
          mix soot.demo.seed      # optional: plant demo tenant + devices
          mix phx.server

        Device-facing endpoints are mounted under the :device_mtls
        pipeline in your router. Admin LiveViews are at /admin.
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
