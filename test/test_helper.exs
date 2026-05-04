# `:phoenix_test_e2e` drives a real `mix phx.new`, runs `mix soot.install`,
# and shells out to `mix test --only phoenix_test` inside the generated
# project. It needs Postgres running locally and takes several minutes.
# Opt in with `mix test --include phoenix_test_e2e`.
ExUnit.start(capture_log: true, exclude: [:phoenix_test_e2e])
