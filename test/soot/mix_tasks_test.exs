defmodule Soot.MixTasksTest do
  use ExUnit.Case, async: false

  @tmp Path.join(System.tmp_dir!(), "soot_mix_tasks_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  describe "mix soot.new (removed)" do
    test "the template generator no longer exists" do
      refute Code.ensure_loaded?(Mix.Tasks.Soot.New)
    end

    test "the project templates were removed from priv/" do
      refute File.exists?(Path.join(:code.priv_dir(:soot) |> to_string(), "templates/project"))
    end
  end

  describe "mix soot.broker.gen_config" do
    test "writes both files by default" do
      out = Path.join(@tmp, "broker")

      capture_io(fn ->
        Mix.Tasks.Soot.Broker.GenConfig.run([
          "--out",
          out,
          "--resource",
          "Soot.Test.Fixtures.Device"
        ])
      end)

      assert File.exists?(Path.join(out, "mosquitto.acl"))
      assert File.exists?(Path.join(out, "mosquitto.conf"))
      assert File.exists?(Path.join(out, "emqx.json"))

      assert File.read!(Path.join(out, "mosquitto.acl")) =~ "tenants/%u/devices/%c/up"

      assert {:ok, %{"acl" => _, "rules" => _}} =
               Jason.decode(File.read!(Path.join(out, "emqx.json")))
    end

    test "--mosquitto-only skips emqx.json" do
      out = Path.join(@tmp, "broker_mosq")

      capture_io(fn ->
        Mix.Tasks.Soot.Broker.GenConfig.run([
          "--out",
          out,
          "--mosquitto-only",
          "--resource",
          "Soot.Test.Fixtures.Device"
        ])
      end)

      assert File.exists?(Path.join(out, "mosquitto.acl"))
      refute File.exists?(Path.join(out, "emqx.json"))
    end

    test "--emqx-only skips mosquitto" do
      out = Path.join(@tmp, "broker_emqx")

      capture_io(fn ->
        Mix.Tasks.Soot.Broker.GenConfig.run([
          "--out",
          out,
          "--emqx-only",
          "--resource",
          "Soot.Test.Fixtures.Device"
        ])
      end)

      refute File.exists?(Path.join(out, "mosquitto.acl"))
      refute File.exists?(Path.join(out, "mosquitto.conf"))
      assert File.exists?(Path.join(out, "emqx.json"))
    end

    test "errors out without --resource" do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Soot.Broker.GenConfig.run(["--out", Path.join(@tmp, "x")])
        end)
      end
    end

    test "rejects --mosquitto-only and --emqx-only together" do
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Mix.Tasks.Soot.Broker.GenConfig.run([
            "--out",
            Path.join(@tmp, "y"),
            "--mosquitto-only",
            "--emqx-only",
            "--resource",
            "Soot.Test.Fixtures.Device"
          ])
        end)
      end
    end

    test "raises when --mosquitto-template points at a non-existent file" do
      out = Path.join(@tmp, "broker_missing_tpl")
      missing = Path.join(@tmp, "no_such_template.eex")

      assert_raise Mix.Error, ~r/--mosquitto-template/, fn ->
        capture_io(fn ->
          Mix.Tasks.Soot.Broker.GenConfig.run([
            "--out",
            out,
            "--mosquitto-template",
            missing,
            "--resource",
            "Soot.Test.Fixtures.Device"
          ])
        end)
      end
    end

    test "substitutes --ca-file/--cert-file/--key-file into mosquitto.conf" do
      out = Path.join(@tmp, "broker_paths")

      capture_io(fn ->
        Mix.Tasks.Soot.Broker.GenConfig.run([
          "--out",
          out,
          "--mosquitto-only",
          "--ca-file",
          "/tmp/example/ca.pem",
          "--cert-file",
          "/tmp/example/server_chain.pem",
          "--key-file",
          "/tmp/example/server_key.pem",
          "--persistence-dir",
          "/tmp/example/mosq-data",
          "--resource",
          "Soot.Test.Fixtures.Device"
        ])
      end)

      conf = File.read!(Path.join(out, "mosquitto.conf"))
      assert conf =~ "cafile /tmp/example/ca.pem"
      assert conf =~ "certfile /tmp/example/server_chain.pem"
      assert conf =~ "keyfile /tmp/example/server_key.pem"
      assert conf =~ "persistence_location /tmp/example/mosq-data"
    end
  end

  defp capture_io(fun), do: ExUnit.CaptureIO.capture_io(fun)
end
