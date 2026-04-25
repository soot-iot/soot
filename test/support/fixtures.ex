defmodule Soot.Test.Fixtures.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Soot.Test.Fixtures.Device
  end
end

defmodule Soot.Test.Fixtures.Device do
  @moduledoc false

  use Ash.Resource,
    domain: Soot.Test.Fixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshMqtt.Resource]

  attributes do
    uuid_primary_key :id
  end

  actions do
    defaults [:read, :destroy, :create]
  end

  mqtt do
    topic "tenants/:tenant_id/devices/:device_id/up", as: :up, direction: :outbound
  end
end
