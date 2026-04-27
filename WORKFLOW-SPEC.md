# Soot — Workflows — Specification

**Status:** Draft v1
**Audience:** Library implementers (continuing where `SPEC.md` and `SPEC-2.md` left off)
**Companion:** `SPEC.md` §5 (Backend Libraries), `DEVICE-SPEC.md` (shadow + command wire shapes)

## 1. Purpose

A declarative workflow engine for Soot operators: trigger flows on device-side state changes (shadow values, command outcomes, enrollment events) or on numeric conditions over the telemetry warehouse (e.g. `CPU > 90% for 10 min`), then run further checks, branches, and actions — issuing MQTT commands, mutating Ash resources, calling external systems.

The framework ships a small set of default workflows that exercise typical Soot surfaces (offline-alert, cert-expiry rotation, segment-threshold notify). Most workflows are written by the operator using the DSL, in their own application — the same way they write Segments and Streams today.

Workflows are first-class Ash extensions with a Spark DSL, persisted run history as Ash resources, an `ash_oban`-backed runtime for execution and durability, and a LiveView visualization surface in `soot_admin` built on **liveflow** (the LiveView-native reactflow analogue).

## 2. Principles

The seven principles in `SPEC.md` §2 still hold. Workflow-specific emphases:

1. **Workflows are operator code, not framework opinions.** The framework ships a DSL, a runtime, a persistence model, and a UI. The flows themselves live in the operator's app like any other Ash module. Defaults are examples and starting points, not load-bearing infrastructure.
2. **Triggers are sources, not magic.** Every trigger maps to an explicit, named source: an Ash notification, an Oban-scheduled query, a webhook, an MQTT subject. No background pollers that aren't visible in the resource graph.
3. **Steps are pure declarations; effects route through Ash.** A `call_action` step invokes an Ash action by name; `publish_command` invokes an `ash_mqtt`-defined action; `query_metric` runs a cloud-side ClickHouse query. The DSL never reaches around the resource layer to do its own IO.
4. **Durable by default.** Every run is an `ash_oban` job chain; every state transition is persisted as an Ash record. A node restart loses no in-flight workflows. This is the *only* reason to introduce `ash_oban` — Soot has no other background-job needs at v0.2.
5. **The graph is the spec.** What renders in the admin (liveflow) is exactly what executes — same node IDs, same edges, derived from the same DSL. No drift between visualization and runtime. There is **no** drag-and-drop authoring in v1; flows are authored in code, the UI is read-only-plus-runs.
6. **Sustained-window conditions are first-class, evaluated in-process.** Numeric triggers like `for: 10.minutes` are a primary use case, not an afterthought. Each active monitor (one workflow × one trigger group key) runs as a supervised GenServer in the cloud service, holding its sliding window in memory via `:dux` (low-level DuckDB+Arrow), fed by the live telemetry hot path. ClickHouse is the source of truth for cold-start hydration and for ad-hoc `:query_metric` steps; it is **not** polled tick-by-tick to evaluate every monitor. `Duxedo` is device-side and not used by cloud workflow code.
7. **Escape hatches.** A `run :module, MyApp.CustomStep` step lets operators drop into arbitrary Elixir for anything the DSL doesn't cover. The DSL is the golden path, not the only path.

## 3. Concept Model

A workflow has three runtime concerns and one design-time concern:

```
        design-time             runtime
        ───────────             ───────────
        Workflow ──────────▶ Trigger ──▶ Run ──▶ Step ──▶ Step ──▶ ...
        (DSL module)         (source)   (Ash    (Oban    (Oban
                                          row)   job)     job)
```

* **Workflow** — a Spark DSL module defining trigger, steps, edges, and metadata. Compile-time artifact; analogous to `SootSegments.Segment`.
* **Trigger** — the source that initiates a Run. One workflow has exactly one trigger (a workflow with two trigger conditions is two workflows; this keeps the model and the diagram clean).
* **Run** — one execution of a workflow against one trigger event. Persisted as `SootWorkflows.Run`, with status (pending/running/succeeded/failed/cancelled), trigger context, current step, started_at/finished_at.
* **Step Execution** — one node's execution within a Run. Persisted as `SootWorkflows.StepExecution` with input, output, status, timestamps. One Oban job per step execution via `ash_oban`.

A Run is conceptually a directed graph traversal. Steps are nodes; control-flow connectors (`branch`, `parallel`, `join`) are edges with semantics. Cycles are rejected at compile time — workflows are DAGs. Long-lived "wait until" semantics are modelled as `wait_for` steps that schedule a future Oban job, not as cycles.

## 4. Library Placement

Adds one row to the `SPEC.md` §4 library map:

| Library | Role | Depends on |
|---|---|---|
| `soot_workflows` | Workflow DSL, runtime, Run/StepExecution resources, monitor supervisor, default workflow modules, liveflow component bundle | `soot_core`, `soot_telemetry`, `ash_mqtt`, `ash_oban`, `:dux` |

`soot_admin` gains a workflow page (admin pages are operator-installed, so this is an opt-in extension to the existing `soot_admin.install` task — not a hard dep on `soot_workflows` from `soot_admin`). The umbrella `soot` package adds `soot_workflows` to its meta-deps.

`soot_workflows` is `soot_*`, not `ash_*`: it is glued tightly to soot_core's device shadow notifications, soot_telemetry's stream identity and ingest hot path, ash_mqtt's command primitives, and the cloud-side ClickHouse client. The monitor processes use `:dux` directly (DuckDB + Arrow as a per-process windowed buffer); they do **not** depend on `:duxedo`, which is a device-side wrapper and out of place on the cloud service. A standalone `ash_workflows` extension may emerge later from common patterns; not in v1 scope.

### New top-level dep: `ash_oban`

Currently absent from the umbrella. Adding it brings Oban (Postgres-backed job queue) and the Ash↔Oban bridge. Implications:

* Postgres becomes mandatory for any operator using `soot_workflows`. Operators on SQLite-only deployments can still ship — they just don't get workflows. Called out in the umbrella docs.
* `ash_oban` config (queue names, prune policy, plugins) lives in the operator's app, generated by an installer in v1.1 (initial v1: hand-wired, documented).
* Oban Pro is **not** required. The default plugins (`Oban.Plugins.Pruner`, `Oban.Plugins.Cron`) are sufficient.

## 5. The DSL

Mirrors the shape of `SootSegments.Segment`. Module-per-workflow; no anonymous workflows.

```elixir
defmodule MyApp.Workflows.HighCPUAlert do
  use SootWorkflows.Workflow

  workflow do
    name :high_cpu_alert
    description "Alert when a device's CPU stays above 90% for 10 minutes."

    trigger :metric_threshold do
      stream :system_metrics
      column :cpu_percent
      group_by [:device_id]
      condition gt: 90
      sustained_for minutes: 10
      evaluate_every minutes: 1
    end

    steps do
      step :warn, :raise_warning do
        severity :warning
        subject {:trigger, :device_id}
        message "CPU above 90% for 10 minutes (current: {{trigger.aggregate_value}}%)"
        clear_on :resolved      # auto-clears when the trigger's `on_clear` fires
      end
    end

    on_failure :log
    retention days: 90
  end
end
```

### DSL surface

* `workflow` (top section): `name`, `description`, `on_failure` (`:log` | `:retry` | `{:run, Module}`), `retention` (`days:` for run history pruning), `concurrency` (one of `:one_per_key`, `:unbounded`; default `:one_per_key` keyed on the trigger's group-by columns).
* `trigger` — exactly one. Nested config depends on the trigger kind. See §6.
* `steps` — ordered list of `step :name, :kind` entries. Step kind determines which inner DSL is valid. See §7.
* Implicit edges: by default each step proceeds to the next listed step on success. `branch` and `goto:` make edges explicit. `parallel … join` constructs are §7.6.
* References: `{:trigger, :field}` reads from the trigger's emitted context; `{:step_name, :output_field}` reads from a prior step's output; `{{path}}` template syntax inside string-typed inputs.

### Compile-time checks

* All `goto:` targets resolve to declared step names.
* No cycles.
* `{:trigger, ...}` references match the trigger schema (each trigger kind exposes a known shape).
* `{:step, :field}` references only target steps reachable on this step's path (forward references in linear order).

## 6. Triggers

Each trigger kind is a separate Spark entity inside the `trigger` section. Operators pick one.

### 6.1 `:shadow_change`

Fires when a device's shadow `reported` map crosses a predicate.

```elixir
trigger :shadow_change do
  resource MyApp.Core.DeviceShadow
  field :firmware_version
  on :transitions_to, value: "1.4.0"
  # alternatively: on :equals, on: :diverges_from_desired, on: :any
end
```

Implementation: subscribes to Ash notifications on `SootCore.DeviceShadow` updates. The notification handler evaluates the predicate, and on match enqueues a Run via `ash_oban`. Notifications are already emitted by the existing `update_reported` action; no new emission code in `soot_core` — only consumption.

The trigger context exposed to steps: `device_id`, `tenant_id`, `previous_value`, `new_value`, `changed_at`.

### 6.2 `:metric_threshold`

Fires when a numeric condition over a telemetry stream holds for a sustained window.

```elixir
trigger :metric_threshold do
  stream :system_metrics
  column :cpu_percent
  group_by [:device_id]
  condition gt: 90
  sustained_for minutes: 10
  reevaluate_every seconds: 30   # optional; defaults to inbound-sample-driven
end
```

`condition` accepts `gt:` / `gte:` / `lt:` / `lte:` / `between: {lo, hi}` / `outside: {lo, hi}`. The aggregation is `:avg` by default; override with `aggregation: :max | :min | :p95 | :count`.

#### Runtime model: per-monitor process

A monitor is one workflow × one trigger group key (e.g. `(MyApp.Workflows.HighCPUWarning, %{device_id: "abc"})`). Each active monitor runs as a `SootWorkflows.Monitor` GenServer, registered in a `Registry` and started under `SootWorkflows.MonitorSupervisor` (a `DynamicSupervisor`).

The monitor process holds the sliding window for its group in memory, using `:dux` (low-level DuckDB + Arrow) as a per-process tabular buffer of recent `(timestamp, value)` rows for the configured `column`. `:dux` is well-suited to this — it is in-process, cheap to instantiate, and gives us SQL-level aggregation over the window without re-implementing percentile/avg/etc. by hand. `:duxedo` is **not** used here: it wraps `:dux` with device-specific concerns (Arrow IPC export, soot_device buffer semantics) that don't apply on the cloud service.

```
                                inbound telemetry hot path
                                          │
                  Phoenix.PubSub  "soot_telemetry:samples:<stream>"
                                          │
                ┌─────────────────────────┼─────────────────────────┐
                ▼                         ▼                         ▼
       Monitor{wf=HighCPU,        Monitor{wf=HighCPU,        Monitor{wf=DeviceOffline,
              dev=abc}                   dev=def}                   dev=abc}
       ┌───────────────┐         ┌───────────────┐          ┌───────────────┐
       │ :dux window   │         │ :dux window   │          │ :dux window   │
       │ ── append ──▶ │         │ ── append ──▶ │          │ ── append ──▶ │
       │ ── query  ──▶ │ aggregate satisfies     │          │ ...           │
       │   value       │ condition? → enqueue Run via       │               │
       └───────────────┘   ash_oban + upsert TriggerState   └───────────────┘
```

Lifecycle:

1. **Boot:** `soot_telemetry`'s ingest hot path broadcasts each accepted sample to `Phoenix.PubSub` topic `soot_telemetry:samples:<stream>`. `SootWorkflows.MonitorRouter` subscribes once per `:metric_threshold` trigger declared in the system. On each inbound sample it computes the group key (from the trigger's `group_by`), looks up or starts the monitor process via `Registry` + `DynamicSupervisor.start_child`, and forwards the sample.
2. **Hydrate on start:** when a monitor starts, it queries ClickHouse for the last `sustained_for` window of samples for its group, loads them into its `:dux` table, and reads `SootWorkflows.TriggerState` to know whether it boots in `:firing` or `:clear`. This makes the system robust to node restarts — a monitor restarted mid-firing does not falsely re-trigger.
3. **On each sample:** append to the `:dux` table; prune rows older than `sustained_for`; re-evaluate the aggregate. If the condition transitions `clear → firing`, enqueue a Run and upsert `TriggerState`. If it transitions `firing → clear`, upsert `TriggerState` and (if the workflow declares `on_clear`) enqueue a clear Run.
4. **Re-evaluation timer (optional):** when `reevaluate_every` is set, the monitor also re-evaluates on a timer even without a new sample. This catches the case where samples stop arriving (e.g. device dropped offline) but the *time-based* nature of the condition (e.g. `count == 0 for 5m`) needs the clock to advance for the predicate to flip.
5. **Idle shutdown:** if no samples and no transitions for `idle_timeout` (default `2 * sustained_for`), the monitor terminates. Its window state is lost, but TriggerState in Postgres persists the firing/clear flag, and the next inbound sample re-hydrates from ClickHouse. This keeps cardinality bounded — a fleet of 100k devices with 5 monitors does not require 500k always-on processes; only the actively-sampling subset has live monitors.

The trigger context exposed to steps: the `group_by` columns (typically `device_id`, `tenant_id`), `aggregate_value`, `threshold`, `window`, `evaluated_at`.

#### Why a process per monitor (not a single cron job)

* **Latency:** detection happens within one sample of the condition becoming true, not within one `evaluate_every` window. For "CPU > 90% for 10m" the first 10 minutes are unavoidable; what we avoid is adding a second cron-tick lag on top.
* **Cost:** 100k devices × 1 sample/min × N monitors as a cron-driven ClickHouse query is wasteful — most groups don't satisfy the condition and shouldn't be re-aggregated every tick. The per-monitor approach only does work where samples are arriving for groups whose conditions are close to flipping.
* **State locality:** the window is small (minutes of one column for one group), well-suited to in-process storage; ClickHouse's strength is large historical aggregation, not millisecond-level windowed re-evaluation per group.
* **Restart safety:** the durable bit (firing vs clear) is in Postgres; the volatile bit (the window itself) rebuilds from ClickHouse on demand. This respects `SPEC.md` §2.2 (OLTP/OLAP separation) — the OLAP store remains the source of truth for the data; only ephemeral evaluation state lives in process memory.

### 6.3 `:command_outcome`

Fires when an MQTT command (defined via `ash_mqtt`) acks, fails, or times out.

```elixir
trigger :command_outcome do
  command MyApp.Commands.Reboot
  on :failure   # | :success | :timeout | :any
end
```

Subscribes to the command-outcome notification emitted by `ash_mqtt`'s runtime client. Trigger context: `device_id`, `command_name`, `outcome`, `error_reason`, `correlation_id`.

### 6.4 `:event`

Generic Ash-domain event hook. Fires when a named action runs on a named resource.

```elixir
trigger :event do
  resource MyApp.Core.Device
  action :transition_to_quarantined
  on :after_action
end
```

Trigger context: the action's input + the resulting record.

### 6.5 `:schedule`

Cron-style. The simplest trigger; useful for periodic maintenance flows (CRL refresh, contract bundle rebuild).

```elixir
trigger :schedule do
  cron "0 3 * * *"  # 03:00 daily
  timezone "UTC"
end
```

Trigger context: `scheduled_at`, `actual_at`.

### 6.6 `:webhook`

Workflow exposes a stable `/api/workflows/:slug/trigger` endpoint that, on receipt of a signed POST, enqueues a Run. The signing secret is per-workflow, generated at install. Useful for external-system integrations (PagerDuty resolution, Grafana alerts coming back in).

Trigger context: the parsed JSON body.

## 7. Steps

Each step kind is a separate Spark entity. The step's `:kind` arg selects the inner schema.

### 7.1 `:call_action`

Invoke an Ash action on a resource.

```elixir
step :get_device, :call_action do
  resource MyApp.Core.Device
  action :get_by_id
  input device_id: {:trigger, :device_id}
  actor :system            # or {:trigger, :actor}
  output_as :device
end
```

Errors propagate to `on_failure`. Output is the action result, available as `{:get_device, ...}` to subsequent steps.

### 7.2 `:publish_command`

Issue an MQTT command via `ash_mqtt`. Wrapper over `:call_action` that knows the command-publishing action shape and surfaces ack/timeout outcomes as step status. Returns the `correlation_id` so a downstream `:wait_for` can pair the ack.

```elixir
step :reboot, :publish_command do
  action MyApp.Commands.Reboot
  device_id {:trigger, :device_id}
  await :ack             # | :no_wait
  timeout seconds: 30
end
```

### 7.3 `:query_metric`

Run an ad-hoc aggregate query against the cloud ClickHouse store and bind the result. Used inside flows for "look up a value to branch on" — distinct from the windowed `:metric_threshold` trigger, which never enters the workflow runtime per evaluation.

```elixir
step :recent_temp_avg, :query_metric do
  stream :sensor_readings
  column :temperature_c
  aggregation :avg
  group_by [:device_id]
  filter device_id: {:trigger, :device_id}
  window minutes: 30
  output_as :temp_avg
end
```

Compiles to a single ClickHouse query issued via the cloud-side `:ch` driver (the same client `soot_telemetry`'s writer uses). Output is the scalar (or per-group map for multi-group queries). This step does **not** use the per-monitor `:dux` window, since `:query_metric` is by definition a one-shot lookup at step-execution time, not a continuously-evaluated condition.

### 7.4 `:branch`

Conditional flow.

```elixir
step :decide, :branch do
  when_match {:temp_avg, gt: 80}, goto: :emergency_shutdown
  when_match {:temp_avg, between: {60, 80}}, goto: :throttle
  else_goto: :resume
end
```

`when_match` patterns are evaluated top-to-bottom; first match wins.

### 7.5 `:wait_for`

Schedule a delayed continuation, or wait for an Ash notification matching a predicate.

```elixir
step :let_it_settle, :wait_for do
  duration minutes: 5
end

step :wait_for_ack, :wait_for do
  notification SootCore.Device, :on_state_change
  match device_id: {:trigger, :device_id}, state: :operational
  timeout minutes: 15
end
```

Implementation: the duration form schedules the next step's Oban job with `scheduled_at:`. The notification form subscribes (per-Run) and snoozes the job until the matching notification arrives or the timeout fires.

### 7.6 `:parallel` and `:join`

Fan-out / fan-in.

```elixir
step :gather, :parallel do
  branches [
    [:fetch_device_info, :recent_metrics, :site_metadata],
    [:peer_status]
  ]
end

step :decide, :join do
  wait_for [:gather]
  mode :all_succeed       # | :any_succeed
end
```

Each parallel branch is a sequential sub-list of step names declared elsewhere in `steps`. The runtime enqueues one Oban job per branch concurrently.

### 7.7 `:run`

The escape hatch. Invokes a behaviour-implementing module.

```elixir
step :custom, :run do
  module MyApp.Workflows.Steps.ReconcileFleet
  input {:trigger, :tenant_id}
end
```

`MyApp.Workflows.Steps.ReconcileFleet` implements `SootWorkflows.Step` (`run/2` returns `{:ok, output}` or `{:error, reason}`). Operator code; the framework imposes no further structure.

### 7.8 `:raise_warning`

Create or update a row in `SootWorkflows.Warning`. The admin UI renders open warnings in a banner on `/admin` and in a dedicated table under `/admin/warnings`. This is the canonical "tell the operator something is wrong" output for a workflow — no email, no pager, no external system, just a first-class in-app surface that doesn't require the operator to wire any notification provider.

```elixir
step :warn, :raise_warning do
  severity :warning            # :info | :warning | :critical
  subject {:trigger, :device_id}
  message "CPU above 90% for 10 minutes (current: {{trigger.aggregate_value}}%)"
  category :high_cpu           # optional grouping key for the admin UI
  clear_on :resolved           # | :run_complete | :manual
end
```

Semantics:

* `clear_on: :resolved` — the warning stays open until the same workflow's trigger fires its `on_clear` path (only meaningful for `:metric_threshold` triggers). The runtime correlates by `(workflow_id, subject, category)`.
* `clear_on: :run_complete` — the warning auto-clears when the Run finishes successfully.
* `clear_on: :manual` — only an operator click in the admin UI clears it.

A `:raise_warning` step is idempotent on `(workflow_id, subject, category)`: re-firing updates `last_seen_at` and `message` rather than creating duplicates. This keeps the admin banner stable across re-evaluations.

### 7.9 `:noop`

Terminal placeholder for `goto:` targets that should end the run silently. Useful for "do nothing if quarantined" branches.

## 8. Runtime — `ash_oban` Integration

Each step execution is one Oban job. The job worker is a single module, `SootWorkflows.Runtime.StepWorker`, which:

1. Loads the `StepExecution` row by ID.
2. Loads the parent `Run` and the workflow module.
3. Materializes the step's input by resolving `{:trigger, _}` and `{:step, _}` references against the run's context.
4. Dispatches to the kind-specific executor (`CallAction`, `PublishCommand`, `QueryMetric`, `Branch`, etc.).
5. Persists the result, updates the `Run.current_step`, and enqueues the next step's job (or marks the Run finished).

`ash_oban` declarations on `SootWorkflows.Run` and `SootWorkflows.StepExecution` give Ash actions for `enqueue` and `complete` that the runtime uses internally. Operators do not write Oban workers directly.

### Idempotency

* Step jobs are unique on `(step_execution_id, attempt_id)`. A retry resumes; it does not duplicate.
* `:call_action` steps assume the action is idempotent. Steps that mutate external systems should expose an explicit `idempotency_key:` input (defaults to `step_execution_id`) which the action implementation may use.
* `:publish_command` carries a stable correlation ID across retries.

### Concurrency

* `concurrency :one_per_key` (default) — at most one Run per `(workflow, trigger_group_key)` is active. New triggers that arrive while a Run is in flight are dropped (with audit row) for `:metric_threshold` (debounce semantics) and queued for `:event` / `:shadow_change` (preserve causal order).
* `concurrency :unbounded` — fan out without coordination. For workflows that must process every event independently (e.g. enrollment-step audits).

### Failure handling

* Step error → marked failed → `Run.on_failure` strategy:
  * `:log` (default): Run marked failed, logged, no further action.
  * `:retry`: re-enqueue the same step with backoff; max 5 attempts, then `:log`.
  * `{:run, Module}`: enqueue a recovery step from a separate handler module.

## 9. Persistence — Resources

All in `SootWorkflows`:

* `SootWorkflows.Workflow` — registry row per declared workflow module. Attributes: `name`, `module`, `version` (DSL hash), `installed_at`. Used by the LiveView page to enumerate workflows without scanning all modules at runtime. Populated at app boot via a single `:after_compile` hook → upsert per module.
* `SootWorkflows.Run` — one per execution. Attributes: `workflow_id`, `trigger_kind`, `trigger_context` (jsonb), `status`, `current_step`, `started_at`, `finished_at`, `error` (jsonb).
* `SootWorkflows.StepExecution` — one per step instance per run. Attributes: `run_id`, `step_name`, `step_kind`, `status`, `input` (jsonb), `output` (jsonb), `started_at`, `finished_at`, `attempts`, `error` (jsonb).
* `SootWorkflows.TriggerState` — one per `(workflow, group_key)` for `:metric_threshold` debouncing. Attributes: `workflow_id`, `group_key` (jsonb), `state` (`:firing` | `:clear`), `since`, `last_evaluated_at`.
* `SootWorkflows.Warning` — operator-visible warnings raised by `:raise_warning` steps. Attributes: `workflow_id`, `source_run_id`, `subject` (string; e.g. device_id), `category` (atom), `severity` (`:info` | `:warning` | `:critical`), `message`, `status` (`:open` | `:cleared`), `raised_at`, `last_seen_at`, `cleared_at`, `cleared_by` (`:auto` | `actor_ref`). Unique constraint on `(workflow_id, subject, category, status: :open)` enforces single-open semantics per the idempotency rule in §7.8.

All five are PG-backed Ash resources. Run/StepExecution are pruned by `Run.retention` (default 90 days) via a daily Oban cron. `Warning` rows in `:cleared` status prune on a separate retention (default 180 days) so historical alerting is auditable for longer than execution traces.

## 10. LiveView Visualization — liveflow

`soot_admin` gains a workflow page (mounted at `/admin/workflows` by the installer; opt-in flag in `soot_admin.install`). Two views:

### 10.1 Workflow definition view (`/admin/workflows/:name`)

Renders the workflow's static graph using **liveflow**: nodes for each step, edges from declared/implicit transitions, color-coded by step kind. Node labels show step name + kind; click expands a side panel with the step's DSL config (read-only, copy-as-elixir).

Trigger is rendered as a fixed leftmost node with kind-specific iconography and a config summary (e.g. `cpu_percent > 90 for 10m, every 1m`).

### 10.2 Run inspector (`/admin/workflows/:name/runs/:id`)

Same liveflow canvas; nodes overlay the executed `StepExecution` status (pending/running/succeeded/failed/skipped). The active node pulses; failed nodes show error excerpt on hover. Clicking a node opens a side panel with input/output JSON and timestamps.

Live updates via Phoenix.PubSub: the runtime broadcasts `{:step_state, run_id, step_name, status}` after each step completes; the LiveView subscribes per-run.

### 10.3 List views

Three Cinder tables follow the existing `soot_admin` pattern:

* `WorkflowTable` — registered workflows, `recent_runs_count`, `success_rate_24h`, link to definition view.
* `RunTable` — recent runs across all workflows; filter by status, workflow, time range; link to run inspector.
* `WarningTable` — open warnings (default filter), with severity, subject, source workflow, message, raised-at; bulk-clear action. Link to the source Run inspector.

These join the existing `@admin_pages` list in `Mix.Tasks.SootAdmin.Install` behind a `--with-workflows` flag (default false in v1; default true once `soot_workflows` ships in the umbrella generator).

### 10.4 Warnings banner

A `SootAdmin.Components.WarningsBanner` LiveComponent renders the count of open warnings (grouped by severity) at the top of every admin page. Clicking through goes to `/admin/warnings`. The component subscribes to `Phoenix.PubSub` topic `soot_workflows:warnings` and updates in real time as new warnings open or clear.

The banner is wired into the operator's `AdminLayouts` template by the installer (§11.1). Operators who don't install `soot_workflows` see no banner and pay no cost.

### 10.5 liveflow integration

### 10.6 liveflow integration

liveflow ships as a dep of `soot_workflows` (or `soot_admin`'s workflow extension; placement TBD during implementation). The mapping from DSL → liveflow graph is a pure function in `SootWorkflows.Graph`:

```elixir
%SootWorkflows.Graph{
  nodes: [
    %{id: "trigger", kind: :trigger, label: "...", config: ...},
    %{id: "fetch_device", kind: :call_action, label: "...", config: ...},
    ...
  ],
  edges: [
    %{from: "trigger", to: "fetch_device", kind: :default},
    %{from: "fetch_device", to: "check_quarantined", kind: :default},
    %{from: "check_quarantined", to: "end_silent", kind: :branch_match, label: "quarantined"},
    %{from: "check_quarantined", to: "notify_oncall", kind: :branch_else},
    ...
  ]
}
```

The same struct feeds both the static view and the run-overlay view; the latter just decorates nodes with status. No drift.

## 11. Installer and Shipped Examples

`soot_workflows` ships an Igniter-driven installer, `mix soot_workflows.install`. Running it once on a Soot-generated app yields a working, end-to-end demonstration of the framework: a runnable workflow, a real warning visible in the admin UI, and the wiring needed for both.

### 11.1 What the installer does

Idempotent (re-runnable, marker-checked, like `mix soot_admin.install`):

1. Adds `:soot_workflows` to the operator's `mix.exs` deps if not present.
2. Adds `:ash_oban` config block (queues, prune cron) to `config/config.exs` if not present, gated behind a `if Code.ensure_loaded?(AshOban)` so SQLite-only deployments still compile.
3. Runs the `soot_workflows` migrations into the operator's repo (Run / StepExecution / TriggerState / Warning / Workflow tables).
4. Generates **one** example workflow at `lib/my_app/workflows/high_cpu_warning.ex` — see §11.2.
5. Wires `SootAdmin.Components.WarningsBanner` into the operator's `AdminLayouts` admin template (idempotency marker on the rendered tag).
6. Mounts `/admin/workflows`, `/admin/workflows/:name`, `/admin/workflows/:name/runs/:id`, and `/admin/warnings` LiveView routes in the router by extending the `ash_authentication_live_session :soot_admin` block. Reuses the existing `@admin_pages` extension mechanism in `Mix.Tasks.SootAdmin.Install`.
7. Prints next-step instructions: how to point the example workflow at the operator's actual CPU telemetry stream, how to trigger it manually for testing, where to find the warning in the admin UI.

The installer **does not** generate any other workflows. The other reference flows (§11.3) live in `SootWorkflows.Defaults.*` and are pulled in à la carte via a separate generator (`mix soot_workflows.gen.example NAME`).

### 11.2 The shipped example: `MyApp.Workflows.HighCPUWarning`

The canonical demonstration. Its job is to prove the whole machine works on the operator's actual deployment with zero additional config beyond pointing at a real CPU stream.

```elixir
defmodule MyApp.Workflows.HighCPUWarning do
  @moduledoc """
  Generated by `mix soot_workflows.install`.

  Raises an admin-UI warning when a device's CPU stays above 90% for
  10 minutes. Clears automatically when CPU drops below 90% for one
  evaluation tick.

  This is a demonstration workflow. Edit the `stream` and `column`
  values to match your telemetry schema. Delete this file to remove
  the example entirely; the rest of soot_workflows is unaffected.
  """

  use SootWorkflows.Workflow

  workflow do
    name :high_cpu_warning
    description "Warn when device CPU > 90% for 10 minutes."
    retention days: 30

    trigger :metric_threshold do
      stream :system_metrics
      column :cpu_percent
      group_by [:device_id]
      condition gt: 90
      sustained_for minutes: 10
      evaluate_every minutes: 1
      aggregation :avg
    end

    steps do
      step :warn, :raise_warning do
        severity :warning
        subject {:trigger, :device_id}
        category :high_cpu
        message "CPU above 90% for 10 minutes (current avg: {{trigger.aggregate_value}}%)"
        clear_on :resolved
      end
    end
  end
end
```

This workflow:

* uses the canonical `:system_metrics` stream from `GENERATOR-SPEC.md` (every Soot-generated app already has it),
* has no external dependencies — no email provider, no PagerDuty, no Slack — so it works the moment migrations run,
* surfaces the result in the admin UI banner and the `/admin/warnings` table,
* auto-clears when CPU drops below threshold, exercising the `:metric_threshold` clear semantics,
* has a doc-block telling the operator exactly what to edit and how to remove it.

Operators with no real device fleet during the install can drive it from `iex`:

```elixir
SootTelemetry.Stream.write(:system_metrics, %{
  device_id: "demo-1", cpu_percent: 95, timestamp_us: System.os_time(:microsecond)
})
```

After 10 minutes of sustained writes, the warning appears in the admin UI. This loop is documented in the README `soot_workflows.install` prints on success.

### 11.3 Other reference workflows (à la carte)

Available via `mix soot_workflows.gen.example NAME`, which copies the named module into the operator's `lib/my_app/workflows/` for editing:

| Module | Trigger | Purpose |
|---|---|---|
| `Defaults.DeviceOffline` | `:metric_threshold` over heartbeat stream, `count == 0 for 5m` | Mark device offline + raise warning |
| `Defaults.CertExpiringSoon` | `:schedule` daily | Find certs expiring < 30d, enqueue rotation, raise info warning |
| `Defaults.SegmentThreshold` | `:metric_threshold`, generic config | Skeleton for operator's per-segment alerts |
| `Defaults.EnrollmentStale` | `:schedule` hourly | Cancel `EnrollmentToken`s pending > 24h |
| `Defaults.ShadowDivergence` | `:shadow_change` `on: :diverges_from_desired` | After 3 ticks divergent, escalate to warning |

Each ships with a doc-block explaining the trigger choice, a tested happy path, and a "things you'll likely change" checklist.

## 12. Phases

Three phases, sequenced. Each phase ends with green CI on `soot_workflows` and an admin demo in the umbrella generator.

### W1 — DSL + persistence + linear runtime (no triggers, no UI)

* `SootWorkflows.Workflow` Spark DSL with `workflow`, `steps`, `:call_action`, `:noop`, `:branch`, `:run`.
* Compile-time validation (graph integrity, reference resolution).
* `Run` and `StepExecution` resources; persistence to Postgres.
* `ash_oban` runtime: enqueue → execute → next step. Linear DAGs only; no parallel/join.
* Programmatic API: `SootWorkflows.start(MyApp.Workflows.Foo, %{trigger_context})`. No real triggers yet.
* Tests: each step kind, branch routing, error → on_failure paths.

### W2 — Real triggers + sustained-window evaluator

* `:shadow_change`, `:event`, `:schedule`, `:command_outcome`, `:webhook`, `:metric_threshold`.
* `TriggerState` resource + the per-monitor `SootWorkflows.Monitor` GenServer, `MonitorRouter` PubSub fan-out from the soot_telemetry hot path, `MonitorSupervisor`, and ClickHouse-backed cold-start hydration via the `:ch` driver.
* `:wait_for`, `:parallel`, `:join`, `:query_metric`, `:publish_command`.
* `concurrency` semantics (one_per_key debouncing).
* Tests: each trigger end-to-end with real Postgres, real Oban, and (for `:metric_threshold`) real ClickHouse for the cold-start hydration path. The per-monitor `:dux` windowing logic is unit-testable in isolation by feeding the `Monitor` GenServer a sequence of samples and asserting transition behavior — no ClickHouse needed for that layer. Full ingest-to-warning integration runs in `soot_workflows`'s integration suite, mirroring `INTEGRATION-SPEC.md`.

### W3 — soot_admin integration + liveflow + installer + warnings

* `SootWorkflows.Graph` struct + DSL→graph compiler.
* `:raise_warning` step kind + `SootWorkflows.Warning` resource + warnings PubSub.
* `soot_admin` workflow pages (definition view, run inspector, list tables) and `WarningsBanner` / `WarningTable`.
* liveflow component bundle, pubsub for live overlays.
* `mix soot_workflows.install` (generates `MyApp.Workflows.HighCPUWarning`, wires admin banner, mounts routes, runs migrations).
* `mix soot_workflows.gen.example NAME` for the other reference workflows.
* Umbrella generator wires `soot_workflows` in by default; `soot_admin.install --with-workflows` becomes default-on.
* Tests: LiveView render tests for both views (status overlay correctness is the hard part), graph compiler property tests, end-to-end installer test (golden-path: install on a fresh Soot-generated app, write CPU telemetry, observe a warning row).

## 13. Open Questions

* **Versioning of in-flight runs across DSL changes.** A workflow whose DSL changes mid-run: do we pin to the version at trigger time (need to persist the compiled graph per run) or migrate forward (lose audit fidelity)? Lean toward pinning; cost is jsonb of the graph per run, which is bounded.
* **Workflow templating.** Operators with many similar workflows (per-tenant variants of the same logic) want parameterization. Out of v1 scope; revisit when concrete demand exists. Workaround: code generation in the operator's app.
* **Cross-workflow signals.** A workflow emitting an event that triggers another workflow is currently expressible only via `:event` on a generic resource. A first-class `:workflow_completed` trigger may be warranted in v1.1 if patterns emerge.
* **liveflow dep maturity.** liveflow is young; if it doesn't expose the hooks we need (custom node renderers, controlled pan/zoom, status overlays), the fallback is a thin SVG renderer in `soot_admin` driven by the same `Graph` struct. Decision deferred to W3 spike.
* **Operator-authored triggers.** v1 triggers are a closed set. A behaviour for custom triggers (`SootWorkflows.Trigger`) is plausible but adds runtime registration complexity. Defer until a real motivating case lands.

## 14. Out of Scope (v1)

* Drag-and-drop authoring in the LiveView. The graph is read-only; flows are code.
* Visual debugging beyond per-step input/output inspection (no time-travel, no breakpoints).
* Multi-tenant workflow isolation beyond what the trigger's filter expresses. Tenancy is the operator's responsibility via `filter`/`group_by`.
* Workflow export/import as JSON. Workflows are Elixir modules; ship them through the operator's normal release pipeline.
* SaaS-style "workflow marketplace." Not a goal of Soot.
* Replay of historical events through a workflow. Possible later via a `:replay` trigger; not in v1.
