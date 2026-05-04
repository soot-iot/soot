defmodule Mix.Tasks.Soot.Gen.PhoenixTestTest do
  use ExUnit.Case, async: false

  import Igniter.Test

  @router """
  defmodule TestWeb.Router do
    use TestWeb, :router

    pipeline :browser do
      plug :accepts, ["html"]
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
    |> Igniter.include_existing_file("lib/test_web/router.ex")
    |> Igniter.include_existing_file("lib/test_web/endpoint.ex")
  end

  describe "info/2" do
    test "declares the documented option schema and aliases" do
      info = Mix.Tasks.Soot.Gen.PhoenixTest.info([], nil)

      assert info.schema == [yes: :boolean]
      assert info.aliases == [y: :yes]
      assert info.group == :soot
      assert info.composes == []
    end
  end

  describe "phoenix_test dependency" do
    test "adds {:phoenix_test, ...} to the test deps" do
      result =
        setup_project()
        |> Igniter.compose_task("soot.gen.phoenix_test", [])

      diff = diff(result, only: "mix.exs")

      assert diff =~ ":phoenix_test"
      assert diff =~ ~s|only: :test|
    end
  end

  describe "test files" do
    test "creates the three integration tests under the operator's web tree" do
      result =
        setup_project()
        |> Igniter.compose_task("soot.gen.phoenix_test", [])

      assert_creates(result, "test/test_web/integration/home_test.exs")
      assert_creates(result, "test/test_web/integration/auth_test.exs")
      assert_creates(result, "test/test_web/integration/admin_test.exs")
    end

    test "rewrites placeholder modules to the operator's app/web modules" do
      result =
        setup_project()
        |> Igniter.compose_task("soot.gen.phoenix_test", [])

      home = diff(result, only: "test/test_web/integration/home_test.exs")
      assert home =~ "TestWeb.Integration.HomeTest"
      assert home =~ "TestWeb.ConnCase"
      refute home =~ "MyAppWeb"
      refute home =~ "MyApp."

      admin = diff(result, only: "test/test_web/integration/admin_test.exs")
      assert admin =~ "TestWeb.Integration.AdminTest"
      assert admin =~ "Test.Accounts.User"
      refute admin =~ "MyAppWeb"
      refute admin =~ "MyApp."
    end

    test "tags every module with @moduletag :phoenix_test" do
      result =
        setup_project()
        |> Igniter.compose_task("soot.gen.phoenix_test", [])

      for path <- [
            "test/test_web/integration/home_test.exs",
            "test/test_web/integration/auth_test.exs",
            "test/test_web/integration/admin_test.exs"
          ] do
        assert diff(result, only: path) =~ "@moduletag :phoenix_test"
      end
    end

    test "is idempotent — re-running skips files that already exist" do
      first =
        setup_project()
        |> Igniter.compose_task("soot.gen.phoenix_test", [])
        |> apply_igniter!()

      second = Igniter.compose_task(first, "soot.gen.phoenix_test", [])

      # If the second run tried to re-create the files, apply_igniter
      # would surface "file already exists" errors. With on_exists:
      # :skip, the second pass is a no-op for the test files.
      assert_unchanged(second, "test/test_web/integration/home_test.exs")
      assert_unchanged(second, "test/test_web/integration/auth_test.exs")
      assert_unchanged(second, "test/test_web/integration/admin_test.exs")
    end
  end

  describe "next-steps notice" do
    test "emits a notice mentioning the :phoenix_test tag" do
      igniter =
        setup_project()
        |> Igniter.compose_task("soot.gen.phoenix_test", [])

      assert Enum.any?(igniter.notices, &(&1 =~ "phoenix_test integration tests generated"))
      assert Enum.any?(igniter.notices, &(&1 =~ "--only phoenix_test"))
    end
  end
end
