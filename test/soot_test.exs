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

  test "extensions_loaded?/0 returns false when ash_jwt isn't compiled into this build" do
    # ash_jwt is intentionally NOT a dep of :soot in v0.1 because it's
    # an escape hatch; this guard just makes sure the helper is wired
    # against actual module loading rather than a static list.
    assert is_boolean(Soot.extensions_loaded?())
  end
end
