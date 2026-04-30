defmodule Mix.Tasks.Soot.InstallTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @router """
  defmodule TestWeb.Router do
    use TestWeb, :router

    pipeline :browser do
      plug :accepts, ["html"]
      plug :fetch_session
      plug :fetch_live_flash
      plug :put_root_layout, html: {TestWeb.Layouts, :root}
      plug :protect_from_forgery
      plug :put_secure_browser_headers
    end

    scope "/", TestWeb do
      pipe_through :browser
      get "/", PageController, :home
    end
  end
  """

  @endpoint """
  defmodule TestWeb.Endpoint do
    use Phoenix.Endpoint, otp_app: :test

    plug TestWeb.Router
  end
  """

  defp setup_project do
    test_project(
      files: %{
        "lib/test_web/endpoint.ex" => @endpoint,
        "lib/test_web/router.ex" => @router
      }
    )
    |> Igniter.Project.Application.create_app(Test.Application)
    |> apply_igniter!()
    # Igniter's test_project uses globs that don't match Path.expand'd
    # paths, so the rewrite source set is empty after apply_igniter!.
    # Manually include the files we need module discovery to find.
    |> Igniter.include_existing_file("lib/test_web/router.ex")
    |> Igniter.include_existing_file("lib/test_web/endpoint.ex")
  end

  describe "info/2" do
    test "declares the per-library installers in the documented order" do
      info = Mix.Tasks.Soot.Install.info([], nil)

      assert info.composes == [
               "ash.install",
               "ash_postgres.install",
               "ash_phoenix.install",
               "ash_authentication.install",
               "ash_authentication_phoenix.install",
               "cinder.install",
               "ash_pki.install",
               "soot_core.install",
               "ash_mqtt.install",
               "soot_telemetry.install",
               "soot_segments.install",
               "soot_contracts.install",
               "soot_admin.install"
             ]
    end

    test "exposes the documented option schema and aliases" do
      info = Mix.Tasks.Soot.Install.info([], nil)

      assert info.schema == [example: :boolean, yes: :boolean, auth_strategy: :string]
      assert info.defaults[:auth_strategy] == "magic_link"
      assert info.aliases == [y: :yes, e: :example]
      assert info.group == :soot
    end

    test "declares ash_postgres in installs so the task is loadable when composed" do
      # `:ash_postgres` is an optional transitive of `:ash_authentication`,
      # so mix won't pull it on its own. Putting it in `info.installs`
      # makes igniter add it to the consumer's mix.exs (and run
      # `mix deps.get`) before `ash_postgres.install` would be composed
      # by `soot.install`, so the task is available.
      info = Mix.Tasks.Soot.Install.info([], nil)

      assert {:ash_postgres, "~> 2.6"} in info.installs
    end

    test "long_doc explains the db_connection workaround constraint" do
      # `:ch`'s `db_connection ~> 2.9.0` conflicts with what phx.new
      # locks (~> 2.10) before soot is fetched, so the pin must be a
      # CLI-level top-level dep — it cannot live inside soot.install.
      doc = Mix.Tasks.Soot.Install.Docs.long_doc()

      assert doc =~ "--install db_connection@2.9.0"
      assert doc =~ "ch"
    end
  end

  describe "router patching" do
    test "adds the :device_mtls pipeline" do
      setup_project()
      |> Igniter.compose_task("soot.install", [])
      |> assert_has_patch("lib/test_web/router.ex", """
      + |  pipeline :device_mtls do
      """)
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    plug(AshPki.Plug.MTLS, require_known_certificate: true)
      """)
    end

    test "mounts the device-facing endpoints under :device_mtls" do
      setup_project()
      |> Igniter.compose_task("soot.install", [])
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    pipe_through [:device_mtls]
      """)
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/enroll", SootCore.Plug.Enroll)
      """)
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/ingest", SootTelemetry.Plug.Ingest)
      """)
      |> assert_has_patch("lib/test_web/router.ex", """
      + |    forward("/.well-known/soot/contract", SootContracts.Plug.WellKnown)
      """)
    end

    test "is idempotent" do
      setup_project()
      |> Igniter.compose_task("soot.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("soot.install", [])
      |> assert_unchanged("lib/test_web/router.ex")
    end

    test "leaves the existing :browser pipeline untouched" do
      diff =
        setup_project()
        |> Igniter.compose_task("soot.install", [])
        |> diff(only: "lib/test_web/router.ex")

      refute diff =~ "- |   pipeline :browser"
      refute diff =~ "- |     plug :fetch_session"
    end
  end

  describe "broker runtime config" do
    test "patches runtime.exs with :ash_mqtt connection config from env" do
      result =
        setup_project()
        |> Igniter.compose_task("soot.install", [])

      diff = diff(result, only: "config/runtime.exs")

      assert diff =~ ":ash_mqtt"
      assert diff =~ ~s|System.get_env("SOOT_BROKER_URL"|
      assert diff =~ ~s|"ssl://localhost:8883"|
      assert diff =~ ~s|System.get_env("SOOT_BROKER_CA"|
      assert diff =~ ~s|"priv/pki/trust_bundle.pem"|
      assert diff =~ ~s|System.get_env("SOOT_BROKER_CERT"|
      assert diff =~ ~s|System.get_env("SOOT_BROKER_KEY"|
    end

    test "is idempotent on runtime.exs" do
      setup_project()
      |> Igniter.compose_task("soot.install", [])
      |> apply_igniter!()
      |> Igniter.compose_task("soot.install", [])
      |> assert_unchanged("config/runtime.exs")
    end
  end

  describe "running on a project without a router" do
    test "emits a warning rather than crashing" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      assert is_struct(igniter, Igniter)

      assert Enum.any?(igniter.warnings, &(&1 =~ "No Phoenix router")),
             "expected a 'No Phoenix router' warning"
    end

    test "skips ash_authentication installers under test_mode with a clear warning" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      skipped =
        igniter.warnings
        |> Enum.filter(&(&1 =~ "Skipping `mix" and &1 =~ "test_mode"))
        |> Enum.map(fn warning ->
          warning
          |> String.split("`mix ", parts: 2)
          |> Enum.at(1)
          |> String.split("`", parts: 2)
          |> hd()
        end)

      # ash_authentication.install / _phoenix.install call
      # `Igniter.apply_and_fetch_dependencies/2` deep in their chain,
      # which is unavailable under `Igniter.Test.test_project/1`. The
      # other composed children behave fine in test_mode and still
      # run.
      assert "ash_authentication.install" in skipped
      assert "ash_authentication_phoenix.install" in skipped
    end
  end

  describe "next-steps notice" do
    test "always emits a Soot installed notice" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "Soot installed."))
      assert Enum.any?(igniter.notices, &(&1 =~ "mix ash.setup"))
      assert Enum.any?(igniter.notices, &(&1 =~ "/admin"))
    end

    test "names the auth strategy in the next-steps notice (default magic_link)" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "Auth strategy: magic_link")
             )
    end

    test "honors an operator-supplied --auth-strategy override" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", ["--auth-strategy", "password"])

      assert Enum.any?(
               igniter.notices,
               &(&1 =~ "Auth strategy: password")
             )

      refute Enum.any?(
               igniter.notices,
               &(&1 =~ "Auth strategy: magic_link")
             )
    end

    test "schedules soot.demo.seed by default (--example is on)" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      assert Enum.any?(igniter.tasks, fn
               {"soot.demo.seed", _, _} -> true
               {"soot.demo.seed", _} -> true
               _ -> false
             end)
    end

    test "does not schedule soot.demo.seed when --no-example is passed" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", ["--no-example"])

      refute Enum.any?(igniter.tasks, fn
               {"soot.demo.seed", _, _} -> true
               {"soot.demo.seed", _} -> true
               _ -> false
             end)
    end
  end

  describe "--example default" do
    test "generates the example DeviceShadow resource by default" do
      result =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      assert_creates(result, "lib/test/devices/device_shadow.ex")

      diff = diff(result, only: "lib/test/devices/device_shadow.ex")
      assert diff =~ "use Ash.Resource"
      assert diff =~ "AshMqtt.Shadow"
      assert diff =~ ":weather_enabled"
      assert diff =~ ":weather_interval_s"
      assert diff =~ ":label"
    end

    test "does not generate DeviceShadow when --no-example is passed" do
      result =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", ["--no-example"])

      refute_creates(result, "lib/test/devices/device_shadow.ex")
    end
  end
end
