defmodule Soot.PhoenixTestE2ETest do
  @moduledoc """
  End-to-end harness for `mix soot.gen.phoenix_test`.

  Mirrors the canonical bootstrap from `README.md` § "Quickstart":

    1. `mix igniter.new <name> --with phx.new --install ash,...,db_connection@2.9.0 --yes`
    2. inject `{:soot, path: …, override: true}` via Igniter so the
       e2e exercises *this* checkout, not the published version
    3. `mix deps.get`
    4. `mix soot.install --yes --no-example`
    5. `mix deps.get` (composed installers may add deps)
    6. `mix soot.gen.phoenix_test --yes`
    7. `mix ash.setup --quiet`
    8. `mix test --only phoenix_test`

  Tagged `:phoenix_test_e2e` and excluded from the default test run by
  `test/test_helper.exs` — opt in with:

      mix test --include phoenix_test_e2e

  Pre-requisites: Postgres reachable on the standard
  `postgres/postgres@localhost:5432` credentials baked into the
  `phx.new` template.

  ## Known blocker (as of 2026-04-30)

  The harness drives steps 1–6 cleanly but `mix ash.setup` (step 7)
  currently fails on a *pre-existing soot installer bug*: several
  child installers (soot_segments, soot_contracts, ash_pki) generate
  operator-namespaced resources (e.g. `MyApp.SegmentRow`) that
  declare `domain: SootSegments.Domain` — but those library-side
  domains' `resources do … end` blocks only list the library's own
  resources, never the operator's. Ash's
  `Ash.Resource.Verifiers.VerifyAcceptedByDomain` raises with no
  escape hatch (`validate_domain_resource_inclusion?` only suppresses
  warnings, not this verifier). Until the installers are fixed, this
  e2e cannot complete.

  When the installer chain is fixed, this test should run
  end-to-end. Until then, the harness still proves that
  `mix soot.gen.phoenix_test` integrates correctly into the canonical
  bootstrap up to compile time.
  """

  use ExUnit.Case, async: false

  @moduletag :phoenix_test_e2e
  @moduletag timeout: :timer.minutes(20)

  @tmp Path.join(System.tmp_dir!(), "soot_phoenix_test_e2e")
  @app_name "soot_phx_test_app"

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  test "phoenix_test integration tests pass against a freshly installed Soot project" do
    soot_path = File.cwd!()
    project_path = Path.join(@tmp, @app_name)

    run_step!(
      ~w(igniter.new #{@app_name} --with phx.new --install ash,ash_postgres,ash_phoenix --install db_connection@2.9.0 --yes),
      cd: @tmp,
      label: "igniter.new"
    )

    inject_soot_path_dep!(project_path, soot_path)

    run_step!(["deps.get"], cd: project_path, label: "deps.get (post-inject)")

    run_step!(["soot.install", "--yes", "--no-example"],
      cd: project_path,
      label: "soot.install"
    )

    # Composed child installers may have added more deps.
    run_step!(["deps.get"], cd: project_path, label: "deps.get (post-soot.install)")

    run_step!(["soot.gen.phoenix_test", "--yes"],
      cd: project_path,
      label: "soot.gen.phoenix_test"
    )

    run_step!(["ash.setup", "--quiet"], cd: project_path, label: "ash.setup")

    {output, code} =
      System.cmd("mix", ["test", "--only", "phoenix_test"],
        cd: project_path,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", "test"}]
      )

    assert code == 0, """
    phoenix_test integration tests failed in the generated project.

    cwd: #{project_path}

    --- mix test --only phoenix_test ---
    #{output}
    """
  end

  defp run_step!(args, opts) do
    label = Keyword.fetch!(opts, :label)
    cd = Keyword.fetch!(opts, :cd)

    {output, code} = System.cmd("mix", args, cd: cd, stderr_to_stdout: true)

    if code != 0 do
      flunk("""
      Step `mix #{Enum.join(args, " ")}` failed (#{label}, exit #{code}).

      cwd: #{cd}

      --- output ---
      #{output}
      """)
    end

    output
  end

  # Adds `{:soot, path: <local>, override: true}` to the operator's
  # deps using Igniter's own dep-rewriting API. Runs in a child Elixir
  # process so the test process's Mix.Project state stays clean —
  # `mix igniter.new` already left `:igniter` compiled in the operator
  # project, so we can call into it from there.
  #
  # `Application.ensure_all_started(:igniter)` is required because
  # Igniter relies on `Rewrite.TaskSupervisor` (and friends) which
  # only start when the `:rewrite` and `:igniter` apps are up.
  #
  # The `:gettext` override is necessary because phx.new pins
  # `~> 0.26` while soot's transitive `cinder` requires `~> 1.0` —
  # without the override, `mix deps.get` fails resolution before any
  # of the soot installers get to run.
  defp inject_soot_path_dep!(project_path, soot_path) do
    script = """
    {:ok, _} = Application.ensure_all_started(:igniter)

    Igniter.new()
    |> Igniter.Project.Deps.add_dep(
      {:soot, [path: #{inspect(soot_path)}, override: true]},
      yes?: true
    )
    |> Igniter.Project.Deps.add_dep(
      {:gettext, "~> 1.0", override: true},
      yes?: true
    )
    |> Igniter.do_or_dry_run(yes: true)
    """

    {output, code} =
      System.cmd("mix", ["run", "--no-start", "--no-deps-check", "-e", script],
        cd: project_path,
        stderr_to_stdout: true
      )

    if code != 0 do
      flunk("""
      Failed to inject :soot path-dep via Igniter (exit #{code}).

      cwd: #{project_path}

      --- output ---
      #{output}
      """)
    end
  end
end
