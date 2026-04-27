#!/usr/bin/env bash
# End-to-end integration reproducer for the Soot framework.
#
# This script is the body of the GHA `integration.yml` workflow and
# the developer's local reproducer. Each stage is independently
# runnable so a developer can iterate on one piece without rerunning
# the whole 16-minute pipeline.
#
#   ./scripts/integration_e2e.sh [stage]
#
# Stages (run in order with `all` or invoke individually):
#
#   setup          docker compose up + verify tooling
#   gen-backend    mix igniter.new + soot.install + path-deps fixup
#   seed           ash_pki.init + ash.setup + soot.demo.seed
#   start-backend  mix run --no-halt in background, wait for /.well-known
#   gen-device     mix nerves.new + mix igniter.install soot_device
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
#   SOOT_E2E_WORKSPACE  Path to the soot workspace (so the generated
#                       projects can pull soot/soot_device via path:).
#                       Default: the directory containing this script's repo.
#   SOOT_E2E_BROKER     emqx (default) or mosquitto. Selects which
#                       broker the device connects to.
#   SKIP_FIRMWARE       Set to 1 to skip the firmware build + QEMU
#                       boot-and-test stages. Useful when iterating on
#                       the backend half locally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOOT_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SOOT_WORKSPACE="${SOOT_E2E_WORKSPACE:-$(cd "$SOOT_REPO/.." && pwd)}"

TMP="${SOOT_E2E_TMP:-/tmp/soot_e2e}"
BACKEND_DIR="$TMP/backend"
DEVICE_DIR="$TMP/device"
BACKEND_PIDFILE="$TMP/backend.pid"
BACKEND_LOG="$TMP/backend.log"
DEVICE_LOG="$TMP/device.log"

BROKER="${SOOT_E2E_BROKER:-emqx}"

case "$BROKER" in
  emqx|mosquitto) ;;
  *) echo "SOOT_E2E_BROKER must be emqx or mosquitto, got: $BROKER" >&2; exit 2 ;;
esac

# Service ports — high host ports so the stack coexists with other
# Postgres / EMQX / ClickHouse instances a developer might be running.
# The container-internal ports stay standard.
export SOOT_E2E_POSTGRES_PORT="${SOOT_E2E_POSTGRES_PORT:-25432}"
export SOOT_E2E_EMQX_MQTT_PORT="${SOOT_E2E_EMQX_MQTT_PORT:-21883}"
export SOOT_E2E_EMQX_MQTTS_PORT="${SOOT_E2E_EMQX_MQTTS_PORT:-28883}"
export SOOT_E2E_EMQX_DASH_PORT="${SOOT_E2E_EMQX_DASH_PORT:-28083}"
export SOOT_E2E_MOSQUITTO_PORT="${SOOT_E2E_MOSQUITTO_PORT:-21884}"
export SOOT_E2E_CH_HTTP_PORT="${SOOT_E2E_CH_HTTP_PORT:-28123}"
export SOOT_E2E_CH_TCP_PORT="${SOOT_E2E_CH_TCP_PORT:-29000}"
export SOOT_E2E_BACKEND_PORT="${SOOT_E2E_BACKEND_PORT:-24000}"

COMPOSE_FILE="$SOOT_REPO/scripts/docker-compose.e2e.yml"

log()  { printf '[soot-e2e %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { log "FAIL: $*"; exit 1; }

# --------------------------------------------------------------------
# setup
# --------------------------------------------------------------------
stage_setup() {
  log "=== setup ==="

  for tool in mix elixir docker qemu-system-aarch64; do
    command -v "$tool" >/dev/null || fail "missing tool: $tool"
  done

  mkdir -p "$TMP"

  log "starting docker services (postgres, $BROKER, clickhouse)"
  docker compose -f "$COMPOSE_FILE" --profile "$BROKER" up -d --wait

  log "waiting for postgres"
  for _ in $(seq 1 30); do
    docker exec soot_e2e_postgres pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done

  case "$BROKER" in
    emqx)
      log "waiting for emqx (host port $SOOT_E2E_EMQX_DASH_PORT)"
      for _ in $(seq 1 30); do
        curl -sf -u admin:soot_e2e_admin "http://localhost:$SOOT_E2E_EMQX_DASH_PORT/api/v5/status" >/dev/null && break
        sleep 1
      done
      ;;
    mosquitto)
      log "waiting for mosquitto (host port $SOOT_E2E_MOSQUITTO_PORT)"
      for _ in $(seq 1 30); do
        # Mosquitto has no HTTP probe — `nc` to the listener port is
        # the closest equivalent.
        if (echo > /dev/tcp/127.0.0.1/$SOOT_E2E_MOSQUITTO_PORT) 2>/dev/null; then
          break
        fi
        sleep 1
      done
      ;;
  esac

  log "waiting for clickhouse (host port $SOOT_E2E_CH_HTTP_PORT)"
  for _ in $(seq 1 30); do
    curl -sf "http://localhost:$SOOT_E2E_CH_HTTP_PORT/ping" >/dev/null && break
    sleep 1
  done

  log "services up (broker=$BROKER)"
}

# --------------------------------------------------------------------
# gen-backend
# --------------------------------------------------------------------
stage_gen_backend() {
  log "=== gen-backend ==="

  rm -rf "$BACKEND_DIR"
  mkdir -p "$(dirname "$BACKEND_DIR")"

  cd "$(dirname "$BACKEND_DIR")"

  # `soot` itself isn't on hex yet, so we can't pass --install soot
  # here. We do install the on-hex pieces that soot.install composes
  # (ash, ash_postgres, ash_phoenix, ash_authentication[_phoenix]) so
  # the umbrella's `composes:` chain finds them when it runs.
  #
  # Once soot ships on hex, the canonical one-liner from
  # GENERATOR-SPEC §3 works and this dance becomes unnecessary.
  log "mix igniter.new $(basename "$BACKEND_DIR") --with phx.new --install <hex-deps>"
  mix igniter.new "$(basename "$BACKEND_DIR")" \
      --install ash,ash_postgres,ash_phoenix,ash_authentication,ash_authentication_phoenix \
      --with phx.new \
      --with-args="--no-mailer --database postgres" \
      --yes

  cd "$BACKEND_DIR"

  log "patching mix.exs to add soot framework path deps"
  patch_backend_mix_exs

  log "patching config/dev.exs + test.exs to point at the e2e Postgres ($SOOT_E2E_POSTGRES_PORT)"
  patch_backend_dev_config

  log "mix deps.get"
  mix deps.get

  log "mix soot.install --yes"
  mix soot.install --yes
}

# Point the generated Phoenix project at the e2e Postgres container's
# port and pin the Phoenix endpoint to a non-default HTTP port to
# avoid colliding with whatever else a developer might be running.
patch_backend_dev_config() {
  python3 <<EOF
import pathlib
import re

pg_port = "$SOOT_E2E_POSTGRES_PORT"
http_port = "$SOOT_E2E_BACKEND_PORT"

for env in ("dev.exs", "test.exs"):
    path = pathlib.Path("config") / env
    if not path.exists():
        continue

    out = []
    inserted = False
    replaced = False
    for line in path.read_text().splitlines(keepends=True):
        stripped = line.lstrip()
        if stripped.startswith('#'):
            out.append(line)
            continue
        if stripped.startswith('port:') and not replaced:
            indent = line[:len(line) - len(stripped)]
            out.append(indent + 'port: ' + pg_port + ',\n')
            replaced = True
            continue
        out.append(line)
        if not inserted and not replaced and stripped.startswith('hostname:'):
            indent = line[:len(line) - len(stripped)]
            out.append(indent + 'port: ' + pg_port + ',\n')
            inserted = True

    path.write_text(''.join(out))

# Phoenix endpoint port — switch the http: [ip: ...] tuple to include port.
dev = pathlib.Path("config/dev.exs")
src = dev.read_text()
new_src, n = re.subn(
    r'http:\s*\[ip:\s*\{127, 0, 0, 1\}\]',
    'http: [ip: {127, 0, 0, 1}, port: ' + http_port + ']',
    src
)
if n > 0:
    dev.write_text(new_src)
EOF
}

# Adds the soot meta-package + per-lib path deps to the generated
# Phoenix mix.exs. This is the "--from-path" escape hatch that
# mix igniter.new doesn't natively offer (see INTEGRATION-SPEC §8
# item 6) — without it, `mix soot.install` would have to look up
# soot on hex (where it doesn't exist yet).
patch_backend_mix_exs() {
  python3 <<EOF
import re
import pathlib

mix_exs = pathlib.Path("mix.exs")
src = mix_exs.read_text()

deps = [
    "soot",
    "ash_pki",
    "ash_mqtt",
    "soot_core",
    "soot_telemetry",
    "soot_segments",
    "soot_contracts",
    "soot_admin",
]

workspace = "$SOOT_WORKSPACE"

new_dep_lines = "\n".join(
    f'      {{:{dep}, path: "{workspace}/{dep}", override: true}},'
    for dep in deps
)

# Pin db_connection to a version that satisfies both ash_postgres
# (which floats freely) and ch (the ClickHouse driver, which requires
# ~> 2.9.0). Without this override, hex resolution fails.
new_dep_lines += '\n      {:db_connection, "~> 2.9.0", override: true},'

# Inject before the closing ] of the deps/0 function.
pattern = re.compile(r'(defp deps do\s*\n\s*\[)', re.MULTILINE)
new_src, n = pattern.subn(r'\1\n' + new_dep_lines, src)

if n == 0:
    raise SystemExit("could not find defp deps in mix.exs")

mix_exs.write_text(new_src)
EOF
}

# --------------------------------------------------------------------
# seed
# --------------------------------------------------------------------
stage_seed() {
  log "=== seed ==="
  cd "$BACKEND_DIR"

  log "mix ash_pki.init --out priv/pki"
  mix ash_pki.init --out priv/pki

  log "mix ash.setup"
  mix ash.setup

  log "mix soot.demo.seed"
  mix soot.demo.seed

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

  log "starting backend (mix phx.server, PORT=$SOOT_E2E_BACKEND_PORT)"
  PORT="$SOOT_E2E_BACKEND_PORT" nohup mix phx.server >"$BACKEND_LOG" 2>&1 &
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
# gen-device
# --------------------------------------------------------------------
stage_gen_device() {
  log "=== gen-device ==="

  rm -rf "$DEVICE_DIR"
  mkdir -p "$(dirname "$DEVICE_DIR")"
  cd "$(dirname "$DEVICE_DIR")"

  log "mix nerves.new $(basename "$DEVICE_DIR") --target qemu_aarch64"
  mix nerves.new "$(basename "$DEVICE_DIR")" --target qemu_aarch64

  cd "$DEVICE_DIR"

  log "patching mix.exs to add soot_device path dep"
  patch_device_mix_exs

  log "mix deps.get (host target)"
  mix deps.get

  bootstrap_pem="$BACKEND_DIR/priv/pki/demo-device-001.cert.pem"
  bootstrap_key="$BACKEND_DIR/priv/pki/demo-device-001.key.pem"

  # We can't `mix igniter.install soot_device` directly because it
  # tries to resolve soot_device on hex first (where it isn't yet).
  # Since we patched mix.exs to add it as a path dep above, the
  # `mix soot_device.install` task is already loaded — invoke it
  # directly.
  if [[ -f "$bootstrap_pem" && -f "$bootstrap_key" ]]; then
    log "mix soot_device.install with baked bootstrap cert"
    mix soot_device.install \
        --bootstrap-cert "$bootstrap_pem" \
        --bootstrap-key  "$bootstrap_key" \
        --yes
  else
    log "no demo bootstrap cert found at $bootstrap_pem — installing without baked credentials"
    mix soot_device.install --yes
  fi
}

patch_device_mix_exs() {
  python3 <<EOF
import re
import pathlib

mix_exs = pathlib.Path("mix.exs")
src = mix_exs.read_text()

workspace = "$SOOT_WORKSPACE"

# Insert soot_device + soot_device_protocol path deps + igniter
# (needed for the install task to be available) into the deps list.
new_deps = """
      {:soot_device, path: "%s/soot_device", override: true},
      {:soot_device_protocol, path: "%s/soot_device_protocol", override: true},
      {:igniter, "~> 0.6", optional: true},""" % (workspace, workspace)

pattern = re.compile(r'(defp deps do\s*\n\s*\[)', re.MULTILINE)
new_src, n = pattern.subn(r'\1' + new_deps, src)

if n == 0:
    raise SystemExit("could not find defp deps in mix.exs")

mix_exs.write_text(new_src)
EOF
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

  log "mix test --include qemu --include e2e"
  mix test --include qemu --include e2e
}

# --------------------------------------------------------------------
# teardown
# --------------------------------------------------------------------
stage_teardown() {
  log "=== teardown ==="

  stage_stop_backend

  if [[ -f "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" --profile all down -v --remove-orphans 2>/dev/null || true
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
