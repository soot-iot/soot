defmodule Mix.Tasks.Soot.Gen.PhoenixTest.Docs do
  @moduledoc false

  def short_doc do
    "Generates phoenix_test integration tests for a Soot-installed project"
  end

  def example do
    "mix soot.gen.phoenix_test"
  end

  def long_doc do
    """
    #{short_doc()}

    Adds `phoenix_test` to the operator's `:test` deps and copies a
    set of integration test templates into `test/<web>/integration/`.
    The templates are maintained as plain Elixir source files in
    `priv/templates/phoenix_test/` of the `soot` package — see that
    directory's README for the placeholder substitution scheme.

    The tests are tagged `@moduletag :phoenix_test` so an operator can
    run only this slice with:

        mix test --only phoenix_test

    The generator is idempotent: re-running it skips files that
    already exist (operators own them post-install).

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

      * `--yes` — answer yes to dependency-fetching prompts.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Soot.Gen.PhoenixTest do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"
    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @template_files ~w(home_test.exs auth_test.exs admin_test.exs)

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :soot,
        example: __MODULE__.Docs.example(),
        only: nil,
        composes: [],
        schema: [yes: :boolean],
        defaults: [yes: false],
        aliases: [y: :yes]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> add_phoenix_test_dep()
      |> copy_test_templates()
      |> Igniter.add_task("deps.get", [])
      |> note_next_steps()
    end

    defp add_phoenix_test_dep(igniter) do
      Igniter.Project.Deps.add_dep(
        igniter,
        {:phoenix_test, "~> 0.7", only: :test, runtime: false}
      )
    end

    defp copy_test_templates(igniter) do
      app_module = Igniter.Project.Module.module_name_prefix(igniter)
      web_module = Igniter.Libs.Phoenix.web_module(igniter)
      app_atom = Igniter.Project.Application.app_name(igniter)

      app_module_str = inspect(app_module)
      web_module_str = inspect(web_module)
      app_atom_str = inspect(app_atom)

      web_subdir = Macro.underscore(web_module_str)

      Enum.reduce(@template_files, igniter, fn filename, igniter ->
        copy_template(
          igniter,
          filename,
          web_subdir,
          app_module_str,
          web_module_str,
          app_atom_str
        )
      end)
    end

    defp copy_template(igniter, filename, web_subdir, app_module, web_module, app_atom) do
      contents =
        filename
        |> template_path()
        |> File.read!()
        |> rewrite_placeholders(app_module, web_module, app_atom)

      destination = Path.join(["test", web_subdir, "integration", filename])

      Igniter.create_new_file(igniter, destination, contents, on_exists: :skip)
    end

    # Order matters: rewrite the more specific `MyAppWeb` token before
    # the more general `MyApp`, otherwise `MyApp` would clobber the
    # `MyApp` prefix inside `MyAppWeb` and the result would be
    # `<web>Web`. Same for the atom form.
    defp rewrite_placeholders(contents, app_module, web_module, app_atom) do
      contents
      |> String.replace("MyAppWeb", web_module)
      |> String.replace("MyApp", app_module)
      |> String.replace(":my_app", app_atom)
    end

    defp template_path(filename) do
      priv = :soot |> :code.priv_dir() |> to_string()
      Path.join([priv, "templates", "phoenix_test", filename])
    end

    defp note_next_steps(igniter) do
      Igniter.add_notice(igniter, """
      phoenix_test integration tests generated.

      The templates were copied into test/<web>/integration/ and are
      tagged `:phoenix_test`. Run them with:

          mix test --only phoenix_test

      Operators own these files — re-running this task will not
      overwrite them. Edit freely.
      """)
    end
  end
else
  defmodule Mix.Tasks.Soot.Gen.PhoenixTest do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"
    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task `soot.gen.phoenix_test` requires igniter. Add
      `{:igniter, "~> 0.6"}` to your project deps and try again, or
      invoke via:

          mix igniter.install soot

      For more information, see https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
