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

  describe "register_path stripping (typical sign_in_route shape)" do
    # Keep the regex tight enough that the result is parseable Elixir.
    # `ash_authentication_phoenix.install` typically generates the
    # `sign_in_route` call with no parens and `register_path:` as the
    # first kwarg, and that's what the install task strips.
    @router_with_sign_in """
    defmodule TestWeb.Router do
      use TestWeb, :router

      scope "/", TestWeb do
        sign_in_route register_path: "/register",
                      reset_path: "/reset",
                      auth_routes_prefix: "/auth",
                      on_mount: [{TestWeb.LiveUserAuth, :live_no_user}]
      end
    end
    """

    test "drops register_path: kwarg and the result is parseable Elixir" do
      project =
        test_project(files: %{"lib/test_web/router.ex" => @router_with_sign_in})
        |> Igniter.Project.Application.create_app(Test.Application)
        |> apply_igniter!()
        |> Igniter.include_existing_file("lib/test_web/router.ex")
        |> Igniter.compose_task("soot.install", [])

      content =
        project.rewrite.sources["lib/test_web/router.ex"]
        |> Rewrite.Source.get(:content)

      refute content =~ "register_path:"
      assert content =~ "sign_in_route"
      assert content =~ "reset_path:"

      # Crucially: still parses as Elixir. The formatter would have
      # rejected my regex output otherwise (cf. soot#14 CI failure
      # before this regex was tightened).
      assert {:ok, _ast} = Code.string_to_quoted(content)
    end
  end

  describe "rewrite_sign_in_with_magic_link/1" do
    # Mirrors the action block `mix ash_authentication.add_strategy magic_link`
    # emits. AshAuthentication's verifier rejects an action of type
    # `:create` named `:sign_in_with_magic_link` once
    # `registration_enabled?` is false, so when the soot install
    # flips that flag we have to flip the action too.
    @generated_user """
    defmodule Test.Accounts.User do
      use Ash.Resource

      actions do
        defaults [:read]

        create :sign_in_with_magic_link do
          description "Sign in or register a user with magic link."

          argument :token, :string do
            description "The token from the magic link that was sent to the user"
            allow_nil? false
          end

          argument :remember_me, :boolean do
            description "Whether to generate a remember me token"
            allow_nil? true
          end

          upsert? true
          upsert_identity :unique_email
          upsert_fields [:email]

          # Uses the information from the token to create or sign in the user
          change AshAuthentication.Strategy.MagicLink.SignInChange

          change {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange,
                  strategy_name: :remember_me}

          metadata :token, :string do
            allow_nil? false
          end
        end
      end
    end
    """

    test "swaps create→read and the result still parses as Elixir" do
      rewritten = Mix.Tasks.Soot.Install.rewrite_sign_in_with_magic_link(@generated_user)

      refute rewritten =~ "create :sign_in_with_magic_link"
      refute rewritten =~ "AshAuthentication.Strategy.MagicLink.SignInChange"
      refute rewritten =~ "argument :remember_me"
      refute rewritten =~ "upsert?"

      assert rewritten =~ "read :sign_in_with_magic_link"
      assert rewritten =~ "AshAuthentication.Strategy.MagicLink.SignInPreparation"

      assert {:ok, _ast} = Code.string_to_quoted(rewritten)
    end

    test "is a no-op when the create block isn't present" do
      content = "defmodule Foo do\n  def bar, do: :baz\nend\n"

      assert Mix.Tasks.Soot.Install.rewrite_sign_in_with_magic_link(content) == content
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

  describe "clickhouse runtime config" do
    test "patches runtime.exs with :soot_telemetry connection config from env" do
      result =
        setup_project()
        |> Igniter.compose_task("soot.install", [])

      diff = diff(result, only: "config/runtime.exs")

      assert diff =~ ":soot_telemetry"
      assert diff =~ ~s|System.get_env("SOOT_CH_URL"|
      assert diff =~ ~s|"http://localhost:8123"|
      assert diff =~ ~s|System.get_env("SOOT_CH_USER"|
      assert diff =~ ~s|"default"|
      assert diff =~ ~s|System.get_env("SOOT_CH_PASSWORD"|
      assert diff =~ "SootTelemetry.Writer.ClickHouse"
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

    test "schedules soot.seed --demo by default (--example is on)" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", [])

      assert Enum.any?(igniter.tasks, fn
               {"soot.seed", ["--demo" | _], _} -> true
               {"soot.seed", ["--demo" | _]} -> true
               _ -> false
             end)
    end

    test "still schedules soot.seed (no --demo) when --no-example is passed" do
      igniter =
        test_project(files: %{})
        |> Igniter.compose_task("soot.install", ["--no-example"])

      assert Enum.any?(igniter.tasks, fn
               {"soot.seed", argv, _} -> "--demo" not in argv
               {"soot.seed", argv} -> "--demo" not in argv
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
