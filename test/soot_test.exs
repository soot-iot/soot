defmodule SootTest do
  use ExUnit.Case, async: true

  test "libraries/0 lists every constituent" do
    libs = Soot.libraries()

    for key <- [
          :ash_pki,
          :ash_mqtt,
          :ash_jwt,
          :soot_core,
          :soot_telemetry,
          :soot_segments,
          :soot_contracts,
          :soot_admin
        ] do
      assert Map.has_key?(libs, key), "missing library #{key} in Soot.libraries/0"
    end
  end

  test "extensions_loaded?/0 returns true on a healthy build" do
    # ash_jwt is intentionally NOT a dep of :soot in v0.1 (it's an
    # opt-in escape hatch) and is flagged `optional?: true` in
    # @libraries. Every other module is a path: dep of :soot, so the
    # helper should report true after a clean compile.
    assert Soot.extensions_loaded?()
  end
end
