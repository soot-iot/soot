defmodule Mix.Tasks.Soot.Broker.PushEmqxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @tmp Path.join(System.tmp_dir!(), "soot_broker_push_emqx_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  defp write_bundle!(name, contents) do
    path = Path.join(@tmp, name)
    File.write!(path, Jason.encode!(contents))
    path
  end

  describe "argument validation" do
    test "errors when --api-key is missing" do
      bundle = write_bundle!("emqx.json", %{"acl" => [], "rules" => []})

      System.delete_env("EMQX_API_KEY")

      assert_raise Mix.Error, ~r/missing --api-key/, fn ->
        Mix.Tasks.Soot.Broker.PushEmqx.run([
          "--in",
          bundle,
          "--api-secret",
          "secret",
          "--dry-run"
        ])
      end
    end

    test "errors when --api-secret is missing" do
      bundle = write_bundle!("emqx.json", %{"acl" => [], "rules" => []})

      System.delete_env("EMQX_API_SECRET")

      assert_raise Mix.Error, ~r/missing --api-secret/, fn ->
        Mix.Tasks.Soot.Broker.PushEmqx.run([
          "--in",
          bundle,
          "--api-key",
          "key",
          "--dry-run"
        ])
      end
    end

    test "reads EMQX_API_KEY / EMQX_API_SECRET / EMQX_API_URL from env when flags absent" do
      bundle = write_bundle!("emqx.json", %{"acl" => [], "rules" => []})

      System.put_env("EMQX_API_KEY", "envkey")
      System.put_env("EMQX_API_SECRET", "envsecret")
      System.put_env("EMQX_API_URL", "http://broker.example:18083")

      try do
        output =
          capture_io(fn ->
            Mix.Tasks.Soot.Broker.PushEmqx.run(["--in", bundle, "--dry-run"])
          end)

        assert output =~ "Pushing #{bundle} to http://broker.example:18083"
        assert output =~ "DRY RUN"
        assert output =~ "Done."
      after
        System.delete_env("EMQX_API_KEY")
        System.delete_env("EMQX_API_SECRET")
        System.delete_env("EMQX_API_URL")
      end
    end
  end

  describe "bundle reading" do
    test "errors when the bundle file does not exist" do
      assert_raise Mix.Error, ~r/EMQX bundle not found/, fn ->
        Mix.Tasks.Soot.Broker.PushEmqx.run([
          "--in",
          Path.join(@tmp, "nope.json"),
          "--api-key",
          "k",
          "--api-secret",
          "s",
          "--dry-run"
        ])
      end
    end

    test "errors when the bundle is invalid JSON" do
      path = Path.join(@tmp, "invalid.json")
      File.write!(path, "not json {")

      assert_raise Mix.Error, ~r/could not parse/, fn ->
        Mix.Tasks.Soot.Broker.PushEmqx.run([
          "--in",
          path,
          "--api-key",
          "k",
          "--api-secret",
          "s",
          "--dry-run"
        ])
      end
    end

    test "errors when the bundle is JSON but not an object" do
      path = Path.join(@tmp, "wrongshape.json")
      File.write!(path, Jason.encode!([1, 2, 3]))

      assert_raise Mix.Error, ~r/expected JSON object/, fn ->
        Mix.Tasks.Soot.Broker.PushEmqx.run([
          "--in",
          path,
          "--api-key",
          "k",
          "--api-secret",
          "s",
          "--dry-run"
        ])
      end
    end
  end

  describe "dry run" do
    test "reports the count of ACLs and rules without making HTTP calls" do
      bundle =
        write_bundle!(
          "emqx.json",
          %{
            "acl" => [%{"type" => "file", "rules" => "{allow, all}."}],
            "rules" => [
              %{"id" => "rule-1", "sql" => "SELECT * FROM \"$events/client_connected\""},
              %{"id" => "rule-2", "sql" => "SELECT 1 FROM \"t/+\""}
            ]
          }
        )

      output =
        capture_io(fn ->
          Mix.Tasks.Soot.Broker.PushEmqx.run([
            "--in",
            bundle,
            "--api-key",
            "k",
            "--api-secret",
            "s",
            "--dry-run"
          ])
        end)

      assert output =~ "1 ACL source(s)"
      assert output =~ "2 rule(s)"
      assert output =~ "DRY RUN"
      refute output =~ "push  "
    end

    test "tolerates missing acl/rules keys" do
      bundle = write_bundle!("emqx.json", %{})

      output =
        capture_io(fn ->
          Mix.Tasks.Soot.Broker.PushEmqx.run([
            "--in",
            bundle,
            "--api-key",
            "k",
            "--api-secret",
            "s",
            "--dry-run"
          ])
        end)

      assert output =~ "0 ACL source(s)"
      assert output =~ "0 rule(s)"
    end
  end
end
