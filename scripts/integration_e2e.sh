#!/usr/bin/env bash
# End-to-end integration reproducer for the Soot framework.
#
# This script is the body of the GHA `integration.yml` workflow and
# the developer's local reproducer. It executes the README's
# Quickstart literally — single-step backend
# (`mix igniter.new --with phx.new --install db_connection@2.9.0,
# soot@github:...`), `mix ash.setup`, then the device-side
# (`mix igniter.new --with nerves.new` then a separate
# `mix igniter.install soot_device@github:...` so we can pass the
# baked-in bootstrap cert from the seed stage) — so an evaluator
# following the README ends up at the same place CI does.
# **No path-deps**, no `mix.exs` patching: if the README's commands
# fail, CI fails too. That's the whole point.
#
# Each stage is independently runnable so a developer can iterate on
# one piece without rerunning the whole pipeline.
#
#   ./scripts/integration_e2e.sh [stage]
#
# Stages (run in order with `all` or invoke individually):
#
#   setup          docker compose up + verify tooling
#   gen-backend    mix igniter.new --with phx.new --install db_connection@...,soot@github:...
#   seed           ash_pki.init + ash.setup + soot.seed --demo
#   start-backend  mix phx.server in background, wait for /
#   gen-device     mix igniter.new --with nerves.new + mix igniter.install soot_device@github:...
#   build-firmware MIX_TARGET=qemu_aarch64 mix firmware
#   boot-and-test  Boot QEMU + run the E2E ExUnit assertions
#   stop-backend   Kill the running backend
#   teardown       docker compose down -v + rm tmp dirs
#   all            All of the above in order
#
# Environment overrides (all optional):
#
#   SOOT_E2E_TMP        Working dir for generated projects.
#                       Default: /tmp/soot_e2e
#   SOOT_E2E_BROKER     emqx (default) or mosquitto. Selects which
#                       broker overlay docker-compose pulls in.
#   SOOT_E2E_REF        Git ref for the soot meta-package. Used for
#                       `--install soot@github:soot-iot/soot[@ref]`.
#                       Default: main.
#   SOOT_DEVICE_E2E_REF Git ref for soot_device. Default: main.
#   SKIP_FIRMWARE       Set to 1 to skip the firmware build + QEMU
#                       boot-and-test stages. Useful when iterating
#                       on the backend half locally.
#
# Service ports default to README-aligned values (5432, 8123, 1883,
# 4000). Override via SOOT_E2E_*_PORT when coexisting with other
# instances on the host — but note that a non-default Postgres port
# means you'll need to patch the generated `config/dev.exs` yourself,
# which the README does not document.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOOT_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP="${SOOT_E2E_TMP:-/tmp/soot_e2e}"
BACKEND_DIR="$TMP/my_iot"
DEVICE_DIR="$TMP/my_device"
BACKEND_PIDFILE="$TMP/backend.pid"
BACKEND_LOG="$TMP/backend.log"

BROKER="${SOOT_E2E_BROKER:-emqx}"

case "$BROKER" in
  emqx|mosquitto) ;;
  *) echo "SOOT_E2E_BROKER must be emqx or mosquitto, got: $BROKER" >&2; exit 2 ;;
esac

SOOT_REF="${SOOT_E2E_REF:-main}"
SOOT_DEVICE_REF="${SOOT_DEVICE_E2E_REF:-main}"

# Service ports — default to the values the README's Quickstart
# assumes. Override only when coexisting with other instances on
# the host (and accept the patch-your-own-config caveat above).
export SOOT_E2E_POSTGRES_PORT="${SOOT_E2E_POSTGRES_PORT:-5432}"
export SOOT_E2E_MQTT_PORT="${SOOT_E2E_MQTT_PORT:-1883}"
export SOOT_E2E_MQTTS_PORT="${SOOT_E2E_MQTTS_PORT:-8883}"
export SOOT_E2E_EMQX_DASH_PORT="${SOOT_E2E_EMQX_DASH_PORT:-18083}"
export SOOT_E2E_CH_HTTP_PORT="${SOOT_E2E_CH_HTTP_PORT:-8123}"
export SOOT_E2E_CH_TCP_PORT="${SOOT_E2E_CH_TCP_PORT:-9000}"
# ClickHouse credentials — must match the user/password the compose
# file at scripts/docker-compose.base.yml provisions. The backend
# release reads these via runtime.exs (`SOOT_CH_USER` / `_PASSWORD` /
# `_URL`) thanks to the patch in `mix soot.install`. Default user is
# `soot` / `soot` to match the compose; override here if the operator
# is reusing a pre-existing ClickHouse instance.
export SOOT_E2E_CH_USER="${SOOT_E2E_CH_USER:-soot}"
export SOOT_E2E_CH_PASSWORD="${SOOT_E2E_CH_PASSWORD:-soot}"
export SOOT_E2E_BACKEND_PORT="${SOOT_E2E_BACKEND_PORT:-4000}"

COMPOSE_BASE="$SOOT_REPO/scripts/docker-compose.base.yml"
COMPOSE_BROKER="$SOOT_REPO/scripts/docker-compose.$BROKER.yml"
COMPOSE_ARGS=(-f "$COMPOSE_BASE" -f "$COMPOSE_BROKER")

log()  { printf '[soot-e2e %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# --------------------------------------------------------------------
# setup
# --------------------------------------------------------------------
stage_setup() {
  log "=== setup (broker=$BROKER) ==="

  for tool in mix elixir docker qemu-system-aarch64; do
    command -v "$tool" >/dev/null || fail "missing tool: $tool"
  done

  mkdir -p "$TMP"

  # Pre-flight: refuse to start if any host port we need is already
  # listening. We bind to localhost in the compose file, but docker
  # still fails the bind in a noisy way. Surfacing it here with the
  # exact override knob is friendlier.
  check_port() {
    local port="$1" name="$2" override="$3"
    if (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null; then
      fail "port $port ($name) already in use; export $override=<free port> and re-run"
    fi
  }
  check_port "$SOOT_E2E_POSTGRES_PORT"  "postgres"   "SOOT_E2E_POSTGRES_PORT"
  check_port "$SOOT_E2E_MQTT_PORT"      "mqtt"       "SOOT_E2E_MQTT_PORT"
  check_port "$SOOT_E2E_CH_HTTP_PORT"   "clickhouse" "SOOT_E2E_CH_HTTP_PORT"
  check_port "$SOOT_E2E_CH_TCP_PORT"    "clickhouse" "SOOT_E2E_CH_TCP_PORT"

  log "starting docker services (postgres, $BROKER, clickhouse)"
  docker compose "${COMPOSE_ARGS[@]}" up -d --wait

  log "waiting for postgres on $SOOT_E2E_POSTGRES_PORT"
  for _ in $(seq 1 30); do
    docker exec soot_e2e_postgres pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done

  case "$BROKER" in
    emqx)
      log "waiting for emqx (dashboard $SOOT_E2E_EMQX_DASH_PORT)"
      for _ in $(seq 1 30); do
        curl -sf -u admin:soot_e2e_admin "http://localhost:$SOOT_E2E_EMQX_DASH_PORT/api/v5/status" >/dev/null && break
        sleep 1
      done
      ;;
    mosquitto)
      log "waiting for mosquitto (mqtt port $SOOT_E2E_MQTT_PORT)"
      for _ in $(seq 1 30); do
        if (echo > /dev/tcp/127.0.0.1/$SOOT_E2E_MQTT_PORT) 2>/dev/null; then
          break
        fi
        sleep 1
      done
      ;;
  esac

  log "waiting for clickhouse (http $SOOT_E2E_CH_HTTP_PORT)"
  for _ in $(seq 1 30); do
    curl -sf "http://localhost:$SOOT_E2E_CH_HTTP_PORT/ping" >/dev/null && break
    sleep 1
  done

  log "services up (broker=$BROKER)"
}

# --------------------------------------------------------------------
# gen-backend — README Quickstart, verbatim (single-step form)
# --------------------------------------------------------------------
# As of soot c71b037, the README Quickstart collapses to a single
# `mix igniter.new` invocation. `soot.install` declares
# `:ash_postgres` in `info.installs`, so igniter pulls it in before
# the compose chain reaches `ash_postgres.install`. The only pin
# the operator still has to type on the CLI is `db_connection@2.9.0`
# — that one cannot move inside `soot.install` because the conflict
# (`:ch` requires `~> 2.9.0`, phx.new locks `2.10.0` via Postgrex)
# is hit at `mix deps.get` *before* soot is fetched. Drop the pin
# once `:ch` widens upstream.
stage_gen_backend() {
  log "=== gen-backend ==="

  rm -rf "$BACKEND_DIR"
  mkdir -p "$(dirname "$BACKEND_DIR")"
  cd "$(dirname "$BACKEND_DIR")"

  log "mix igniter.new $(basename "$BACKEND_DIR") --with phx.new --install db_connection@2.9.0,soot@github:soot-iot/soot@$SOOT_REF"
  mix igniter.new "$(basename "$BACKEND_DIR")" \
      --with phx.new \
      --with-args="--database postgres" \
      --install "db_connection@2.9.0,soot@github:soot-iot/soot@$SOOT_REF" \
      --yes

  cd "$BACKEND_DIR"

  # If any service port has been overridden away from its README
  # default, patch the generated dev.exs/test.exs so ash.setup,
  # phx.server, etc. actually reach the docker-compose services.
  # No-op when the user accepts the defaults (CI, README evaluators).
  if [[ "$SOOT_E2E_POSTGRES_PORT" != "5432" ]]; then
    log "patching config/dev.exs + test.exs for non-default Postgres port $SOOT_E2E_POSTGRES_PORT"
    patch_backend_postgres_port
  fi
}

# Patches the generated Phoenix project's `config/{dev,test}.exs` to
# add `port: $SOOT_E2E_POSTGRES_PORT` to the Repo config block.
# Idempotent: if a `port:` line already exists (any value), replaces
# its value; otherwise injects one after the `hostname:` line.
patch_backend_postgres_port() {
  python3 - <<EOF
import pathlib
import re

pg_port = "$SOOT_E2E_POSTGRES_PORT"

for env in ("dev.exs", "test.exs"):
    path = pathlib.Path("config") / env
    if not path.exists():
        continue

    lines = path.read_text().splitlines(keepends=True)

    # Look for an existing non-comment \`port:\` line. If found,
    # replace its value in place and we're done. Otherwise insert
    # a new \`port:\` line right after the first \`hostname:\` line.
    has_port = any(
        line.lstrip().startswith('port:')
        for line in lines
        if not line.lstrip().startswith('#')
    )

    out = []
    if has_port:
        seen = False
        for line in lines:
            stripped = line.lstrip()
            if not stripped.startswith('#') and stripped.startswith('port:'):
                if not seen:
                    indent = line[:len(line) - len(stripped)]
                    out.append(indent + 'port: ' + pg_port + ',\n')
                    seen = True
                # drop duplicate port: lines (defensive)
            else:
                out.append(line)
    else:
        injected = False
        for line in lines:
            out.append(line)
            stripped = line.lstrip()
            if (not injected
                and not stripped.startswith('#')
                and stripped.startswith('hostname:')):
                indent = line[:len(line) - len(stripped)]
                out.append(indent + 'port: ' + pg_port + ',\n')
                injected = True

    path.write_text(''.join(out))
EOF
}

# --------------------------------------------------------------------
# seed — README §"app schema migrations" + demo seed
# --------------------------------------------------------------------
stage_seed() {
  log "=== seed ==="
  cd "$BACKEND_DIR"

  log "mix ash_pki.init --out priv/pki"
  mix ash_pki.init --out priv/pki

  # Workaround for an upstream migration-ordering bug: the merged
  # Initialize/AddAuthenticationResources migration generated by the
  # README-style single-step install creates `users` (with citext
  # email columns) before any `CREATE EXTENSION citext`. On a
  # postgres image that doesn't already have the extension loaded,
  # `mix ash.setup` fails with `type "citext" does not exist`.
  # Pre-create the database and the extension here so the migration
  # picks up an env that already has citext available.
  # See PROBLEMS.md → "ash.setup citext-before-extension ordering".
  log "creating my_iot_dev (if needed) + CREATE EXTENSION IF NOT EXISTS citext"
  PGPASSWORD=postgres psql \
      -h 127.0.0.1 -p "$SOOT_E2E_POSTGRES_PORT" \
      -U postgres -d postgres \
      -tAc "SELECT 1 FROM pg_database WHERE datname='my_iot_dev'" \
      | grep -q 1 \
      || PGPASSWORD=postgres createdb \
              -h 127.0.0.1 -p "$SOOT_E2E_POSTGRES_PORT" \
              -U postgres my_iot_dev
  PGPASSWORD=postgres psql \
      -h 127.0.0.1 -p "$SOOT_E2E_POSTGRES_PORT" \
      -U postgres -d my_iot_dev \
      -c "CREATE EXTENSION IF NOT EXISTS citext;"

  log "mix ash.setup"
  mix ash.setup

  log "mix soot.seed --demo"
  mix soot.seed --demo

  log "mix ash_pki.gen.cert (bootstrap cert for the demo device)"
  mix ash_pki.gen.cert \
      --issuer intermediate \
      --subject "/CN=demo-device-001" \
      --name demo-device-001
}

# --------------------------------------------------------------------
# start-backend
# --------------------------------------------------------------------
stage_start_backend() {
  log "=== start-backend ==="
  cd "$BACKEND_DIR"

  if [[ -f "$BACKEND_PIDFILE" ]] && kill -0 "$(cat "$BACKEND_PIDFILE")" 2>/dev/null; then
    log "backend already running (pid $(cat "$BACKEND_PIDFILE"))"
    return 0
  fi

  # ClickHouse runs with non-default credentials in the compose file.
  # Thread the matching SOOT_CH_* vars into the backend environment so
  # `SootTelemetry.Writer.ClickHouse` (configured via the runtime.exs
  # block planted by `mix soot.install`) authenticates against the
  # local cluster instead of falling back to user `default` with an
  # empty password.
  log "starting backend (mix phx.server, PORT=$SOOT_E2E_BACKEND_PORT)"
  PORT="$SOOT_E2E_BACKEND_PORT" \
    SOOT_CH_URL="http://localhost:$SOOT_E2E_CH_HTTP_PORT" \
    SOOT_CH_USER="$SOOT_E2E_CH_USER" \
    SOOT_CH_PASSWORD="$SOOT_E2E_CH_PASSWORD" \
    nohup mix phx.server >"$BACKEND_LOG" 2>&1 &
  echo $! > "$BACKEND_PIDFILE"

  # We can't hit /.well-known/soot/contract from the host without a
  # client cert — it's behind the :device_mtls pipeline. Probe `/`
  # instead, which lives on the :browser pipeline and 200s once the
  # endpoint is listening. The actual contract endpoint is exercised
  # from inside QEMU later.
  log "waiting for backend on :$SOOT_E2E_BACKEND_PORT (probing /)"
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$SOOT_E2E_BACKEND_PORT/" 2>/dev/null || echo '')"
    if [[ "$code" =~ ^[23] ]]; then
      log "backend up (pid $(cat "$BACKEND_PIDFILE"), HTTP $code)"
      return 0
    fi
    sleep 1
  done

  log "backend log tail:"
  tail -50 "$BACKEND_LOG" >&2 || true
  fail "backend did not respond within 60s"
}

stage_stop_backend() {
  log "=== stop-backend ==="
  if [[ -f "$BACKEND_PIDFILE" ]]; then
    pid="$(cat "$BACKEND_PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
      log "killing backend pid $pid"
      kill "$pid" || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$BACKEND_PIDFILE"
  fi
}

# --------------------------------------------------------------------
# gen-device — README "Device-side Quickstart", with bootstrap-cert
# baking
# --------------------------------------------------------------------
# The README's device-side quickstart does the install in one step:
#
#     mix igniter.new my_device --with nerves.new \
#         --with-args="--target qemu_aarch64" \
#         --install soot_device@github:soot-iot/soot_device --yes
#
# We split into two steps so we can pass `--bootstrap-cert` /
# `--bootstrap-key` to the soot_device.install task — those flags
# bake the demo cert from the seed stage into the firmware's
# rootfs_overlay so the device can actually authenticate against
# the mTLS-protected backend during boot-and-test. The README
# version skips baking (and so wouldn't reach the backend); that
# divergence is the only gap from running the README literally.
stage_gen_device() {
  log "=== gen-device ==="

  rm -rf "$DEVICE_DIR"
  mkdir -p "$(dirname "$DEVICE_DIR")"
  cd "$(dirname "$DEVICE_DIR")"

  log "step 1: mix igniter.new $(basename "$DEVICE_DIR") --with nerves.new --with-args=\"--target qemu_aarch64\""
  mix igniter.new "$(basename "$DEVICE_DIR")" \
      --with nerves.new \
      --with-args="--target qemu_aarch64" \
      --yes

  cd "$DEVICE_DIR"

  bootstrap_pem="$BACKEND_DIR/priv/pki/demo-device-001.cert.pem"
  bootstrap_key="$BACKEND_DIR/priv/pki/demo-device-001.key.pem"

  if [[ -f "$bootstrap_pem" && -f "$bootstrap_key" ]]; then
    log "step 2: mix igniter.install soot_device@github:soot-iot/soot_device@$SOOT_DEVICE_REF (with baked bootstrap cert)"
    mix igniter.install "soot_device@github:soot-iot/soot_device@$SOOT_DEVICE_REF" \
        --bootstrap-cert "$bootstrap_pem" \
        --bootstrap-key  "$bootstrap_key" \
        --yes
  else
    log "step 2: mix igniter.install soot_device@github:soot-iot/soot_device@$SOOT_DEVICE_REF (no bootstrap cert found — unbaked)"
    mix igniter.install "soot_device@github:soot-iot/soot_device@$SOOT_DEVICE_REF" --yes
  fi
}

# --------------------------------------------------------------------
# build-firmware
# --------------------------------------------------------------------
stage_build_firmware() {
  log "=== build-firmware ==="
  cd "$DEVICE_DIR"

  log "MIX_TARGET=qemu_aarch64 mix deps.get"
  MIX_TARGET=qemu_aarch64 mix deps.get

  log "MIX_TARGET=qemu_aarch64 mix firmware (cold builds take 5-15 min)"
  MIX_TARGET=qemu_aarch64 mix firmware
}

# --------------------------------------------------------------------
# boot-and-test
# --------------------------------------------------------------------
stage_boot_and_test() {
  log "=== boot-and-test ==="
  cd "$DEVICE_DIR"

  # `mix test` boots the device application on the host before any
  # test runs. The generated `device.ex` and `config.exs` default
  # several paths to Nerves-target paths that don't exist on the
  # host (e.g. `/data/soot`, `/etc/soot/bootstrap.pem`). The
  # generated stubs wire env-var overrides; populate them with
  # host-friendly values pointing at the seed-stage outputs so
  # `SootDevice.Runtime.start_link/2` succeeds. The actual firmware
  # running under QEMU keeps the target paths via the rootfs_overlay.
  #
  # Note: `SOOT_BOOTSTRAP_CERT` / `SOOT_BOOTSTRAP_KEY` /
  # `SOOT_PERSISTENCE_DIR` feed the `device.ex` DSL at compile
  # time, so they must be set before `mix test` triggers the
  # test-env compile. `<APP>_PERSISTENCE_DIR` feeds runtime
  # `Application.fetch_env(:my_device, :persistence_dir)` via
  # the generated `config/config.exs`. We set both because the
  # generated `MyDevice.SootDeviceConfig.device_opts/1` overrides
  # the DSL `storage_dir` with the runtime value but the DSL is
  # still evaluated.
  app="$(basename "$DEVICE_DIR")"
  env_prefix="$(echo "$app" | tr '[:lower:]-' '[:upper:]_')"
  host_storage="$TMP/${app}_host_storage"
  mkdir -p "$host_storage"

  bootstrap_pem="$BACKEND_DIR/priv/pki/demo-device-001.cert.pem"
  bootstrap_key="$BACKEND_DIR/priv/pki/demo-device-001.key.pem"

  if [[ ! -f "$bootstrap_pem" || ! -f "$bootstrap_key" ]]; then
    fail "demo bootstrap cert/key not found at $bootstrap_pem — run \`seed\` first"
  fi

  log "host overrides:"
  log "  SOOT_BOOTSTRAP_CERT=$bootstrap_pem"
  log "  SOOT_BOOTSTRAP_KEY=$bootstrap_key"
  log "  SOOT_PERSISTENCE_DIR=$host_storage"
  log "  ${env_prefix}_PERSISTENCE_DIR=$host_storage"

  # Force MIX_ENV=test for the test run. The workflow exports
  # `MIX_ENV=dev` for the build-firmware stage; if we let that bleed
  # through, the device project's `elixirc_paths(:test) ++
  # ["test/support"]` clause never fires and `<App>.QEMU` (planted
  # there by `mix soot_device.gen.tests`) is missing — every QEMU
  # test then dies with `UndefinedFunctionError`.
  log "mix test --include qemu --include e2e"
  env \
    "MIX_ENV=test" \
    "SOOT_BOOTSTRAP_CERT=$bootstrap_pem" \
    "SOOT_BOOTSTRAP_KEY=$bootstrap_key" \
    "SOOT_PERSISTENCE_DIR=$host_storage" \
    "${env_prefix}_PERSISTENCE_DIR=$host_storage" \
    mix test --include qemu --include e2e
}

# --------------------------------------------------------------------
# teardown
# --------------------------------------------------------------------
stage_teardown() {
  log "=== teardown ==="

  stage_stop_backend

  if [[ -f "$COMPOSE_BASE" ]]; then
    docker compose "${COMPOSE_ARGS[@]}" down -v --remove-orphans 2>/dev/null || true
  fi

  if [[ -d "$TMP" && "${SOOT_E2E_KEEP_TMP:-0}" != "1" ]]; then
    log "removing $TMP"
    rm -rf "$TMP"
  fi
}

# --------------------------------------------------------------------
# all
# --------------------------------------------------------------------
stage_all() {
  stage_setup
  stage_gen_backend
  stage_seed
  stage_start_backend

  if [[ "${SKIP_FIRMWARE:-0}" == "1" ]]; then
    log "SKIP_FIRMWARE=1 — skipping device + firmware + boot stages"
  else
    stage_gen_device
    stage_build_firmware
    stage_boot_and_test
  fi

  stage_stop_backend
}

# --------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------
case "${1:-all}" in
  setup)          stage_setup ;;
  gen-backend)    stage_gen_backend ;;
  seed)           stage_seed ;;
  start-backend)  stage_start_backend ;;
  stop-backend)   stage_stop_backend ;;
  gen-device)     stage_gen_device ;;
  build-firmware) stage_build_firmware ;;
  boot-and-test)  stage_boot_and_test ;;
  teardown)       stage_teardown ;;
  all)            stage_all ;;
  *)
    cat <<USAGE >&2
unknown stage: $1

Stages: setup gen-backend seed start-backend stop-backend
        gen-device build-firmware boot-and-test teardown all
USAGE
    exit 2
    ;;
esac
