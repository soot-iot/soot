defmodule Mix.Tasks.Soot.New do
  @shortdoc "Scaffold a new Soot-framework project"

  @moduledoc """
  Generate a new project pre-wired with the Soot framework libraries.

      mix soot.new my_iot

  Produces a directory `my_iot/` with:

    * `mix.exs` listing every Soot library as a hex dep
    * `lib/my_iot.ex` and `lib/my_iot/application.ex`
    * `lib/my_iot/endpoint.ex` — Plug router with the Soot endpoints
      mounted under `AshPki.Plug.MTLS`
    * `README.md` — first-time-setup checklist that walks the operator
      through the deployment runbook

  The generated project does not yet contain any Ash domains or
  resources — operators add their own using the framework libraries'
  generators (`mix ash.gen.domain`, `mix ash.gen.resource`, etc.).

  Options:
    * `--module Name` — override the inferred module name
      (default: `app_name |> Macro.camelize/1`).
    * `--into <path>` — write into an existing directory instead of
      creating a new one. Files are written in-place; existing files
      are *not* overwritten unless `--force` is given.
    * `--force` — overwrite existing files.
  """

  use Mix.Task

  @switches [module: :string, into: :string, force: :boolean]

  @template_dir Path.expand("../../../priv/templates/project", __DIR__)

  @impl Mix.Task
  def run([]), do: Mix.raise("Usage: mix soot.new <app_name> [--module Name] [--into path]")

  def run(argv) do
    {opts, [app_name | _]} = OptionParser.parse!(argv, strict: @switches)
    app = String.replace(app_name, "-", "_") |> String.downcase()
    module = Keyword.get(opts, :module, Macro.camelize(app))
    into = Keyword.get(opts, :into, app)
    force? = Keyword.get(opts, :force, false)

    File.mkdir_p!(into)

    bindings = [app: app, module: module]

    [
      {"mix.exs.eex", "mix.exs"},
      {"application.ex.eex", "lib/#{app}/application.ex"},
      {"endpoint.ex.eex", "lib/#{app}/endpoint.ex"},
      {"README.md.eex", "README.md"}
    ]
    |> Enum.each(fn {template, target} ->
      contents =
        Path.join(@template_dir, template)
        |> EEx.eval_file(bindings)

      target_path = Path.join(into, target)
      File.mkdir_p!(Path.dirname(target_path))
      write_file(target_path, contents, force?)
    end)

    Mix.shell().info("""

    ==> Generated #{module} in #{into}/

    Next:

      cd #{into}
      mix deps.get
      mix ash_pki.init --out priv/pki

    See README.md in the new project for the full bring-up checklist.
    """)
  end

  defp write_file(path, contents, force?) do
    cond do
      not File.exists?(path) ->
        File.write!(path, contents)
        Mix.shell().info("    create  #{path}")

      force? ->
        File.write!(path, contents)
        Mix.shell().info("    force   #{path}")

      true ->
        Mix.shell().info("    skip    #{path} (exists; pass --force to overwrite)")
    end
  end
end
