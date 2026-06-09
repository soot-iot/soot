defmodule Soot.PhoenixTestE2ETest do
  @moduledoc """
  End-to-end harness for `mix soot.gen.phoenix_test`.

  Mirrors the canonical bootstrap from `README.md` § "Quickstart" —
  the one-step recipe introduced in c71b037 (`soot.install` declares
  `:ash_postgres` in `info.installs`, so a single `mix igniter.new`
  invocation pulls the whole stack):

    1. `mix igniter.new <name> --with phx.new --with-args="--database postgres" --install db_connection@2.9.0 --yes`
       (soot is intentionally *not* in `--install` — we add it as a
       path-dep next)
    2. inject `{:soot, path: …, override: true}` and `:ash_postgres`
       via Igniter. The ash_postgres dep mirrors what soot.install's
       `info.installs` would have added if invoked through
       `mix igniter.install soot@github:...` — `mix igniter.install`
       can't accept path-dep specs, so we add the install-spec deps
       explicitly here.
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

  ## Known blocker (as of 2026-05-04)

  The harness drives steps 1–7 cleanly and lands at step 8
  (`mix test --only phoenix_test`) inside the operator project. As of
  this writing, 1 of the 5 phoenix_test smoke tests passes (`GET /`)
  and 4 fail. Root cause is in `mix soot.install`'s compose chain,
  not in the gen task or the templates:

    * `ash_postgres.install` is composed but errors with
      "lib/<app>/repo.ex: File already exists" — the
      `include_existing_marker_files/1` helper isn't actually making
      the existing `Repo` module visible to the upstream installer's
      create-or-update path. The Ecto.Repo→AshPostgres.Repo
      conversion is therefore skipped, and the rest of the chain
      (ash_authentication, soot_admin, …) doesn't generate its
      operator-namespaced modules. Result: `Accounts.User` and the
      `/admin` + `/sign-in` routes never appear in the operator
      project, so any phoenix_test that touches them fails.

    * The library-domain resource registration bug from PR #15 is
      still latent — it would surface later in the chain if the
      ash_postgres compose succeeded.

  Set `SOOT_E2E_KEEP=1` to keep the operator project on disk after a
  failing run for inspection.
  """

  use ExUnit.Case, async: false

  @moduletag :phoenix_test_e2e
  @moduletag timeout: :timer.minutes(20)

  @tmp Path.join(System.tmp_dir!(), "soot_phoenix_test_e2e")
  @app_name "soot_phx_test_app"

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    # Keep the tmpdir around when the SOOT_E2E_KEEP env is set so a
    # failing run leaves the operator project on disk for inspection.
    if System.get_env("SOOT_E2E_KEEP") not in ["1", "true"] do
      on_exit(fn -> File.rm_rf!(@tmp) end)
    end

    :ok
  end

  test "phoenix_test integration tests pass against a freshly installed Soot project" do
    soot_path = File.cwd!()
    project_path = Path.join(@tmp, @app_name)

    run_step!(
      [
        "igniter.new",
        @app_name,
        "--with",
        "phx.new",
        "--with-args=--database postgres",
        "--install",
        "db_connection@2.9.0",
        "--yes"
      ],
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
  # Several extra deps land alongside `:soot`:
  #
  #   * `{:gettext, "~> 1.0", override: true}` — phx.new pins
  #     `~> 0.26` and soot's transitive `cinder` requires `~> 1.0`;
  #     without the override `mix deps.get` fails before any soot
  #     installer runs.
  #   * `:ash_postgres` / `:ash_phoenix` / `:ash_authentication` /
  #     `:ash_authentication_phoenix` — when the canonical bootstrap
  #     uses `mix igniter.install soot@github:...`, igniter walks
  #     soot.install's compose chain and auto-installs each composed
  #     task's package via `info.installs` propagation. We invoke
  #     `mix soot.install` directly (because `igniter.install` can't
  #     accept a path-dep spec), and soot.install's
  #     `compose_children` *skips* tasks whose package is missing
  #     with a warning rather than installing it. So we have to seed
  #     every package the chain needs before invoking soot.install.
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
    |> Igniter.Project.Deps.add_dep({:ash_postgres, "~> 2.6"}, yes?: true)
    |> Igniter.Project.Deps.add_dep({:ash_phoenix, "~> 2.0"}, yes?: true)
    |> Igniter.Project.Deps.add_dep({:ash_authentication, "~> 4.0"}, yes?: true)
    |> Igniter.Project.Deps.add_dep({:ash_authentication_phoenix, "~> 2.0"}, yes?: true)
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
