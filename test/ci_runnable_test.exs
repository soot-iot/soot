defmodule CIRunnableTest do
  @moduledoc """
  Runs the bash self-test for the CI-RUNNABLE markdown extractor
  (`scripts/extract_ci_runnable.sh` + `scripts/run_ci_runnable.sh`)
  as part of `mix test`, so the project-wide CI suite covers it
  without a separate workflow step.

  The bash test (`scripts/test/extract_ci_runnable_test.sh`) is the
  authoritative source of assertions; this Elixir wrapper exists
  only to surface its exit status to ExUnit.
  """

  use ExUnit.Case, async: true

  @bash_test Path.expand("../scripts/test/extract_ci_runnable_test.sh", __DIR__)

  test "extract_ci_runnable.sh self-test passes" do
    assert File.exists?(@bash_test),
           "expected bash self-test at #{@bash_test}"

    {output, status} = System.cmd("bash", [@bash_test], stderr_to_stdout: true)

    assert status == 0, """
    bash self-test exited with status #{status}.

    --- stdout / stderr ---
    #{output}
    """
  end
end
