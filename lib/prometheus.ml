(** Prometheus-Compatible Metrics for masc-mcp

    Provides lightweight metrics collection and Prometheus text format export.

    Usage:
    {[
      let () = Prometheus.inc_counter "masc_tasks_total" ~labels:[("status", "completed")]
      let () = Prometheus.set_gauge "masc_active_agents" 5.0
      let text = Prometheus.to_prometheus_text ()
    ]}

    @since 0.4.0
*)

(** {1 Metric Types} *)

type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric = {
  name: string;
  help: string;
  metric_type: metric_type;
  mutable value: float;
  labels: label list;
}

(** {1 Global Metrics Store}

    [metrics] is updated from any fiber on any domain — LLM telemetry,
    keeper heartbeats, SSE bookkeeping, HTTP handlers. The previous
    implementation used a bare [Hashtbl.t] with [find_opt] + [add] which
    has two race windows:

    1. TOCTOU on registration: two fibers call [inc_counter] on a new
       key, both see [None], both [Hashtbl.add] — duplicate entries in
       the table.
    2. Non-atomic float update: [m.value <- m.value +. delta] reads,
       adds, writes without a memory barrier; two concurrent increments
       can both observe the same old value.

    We serialise every read and write path through [Stdlib.Mutex].
    Choice of primitive: operations must work during module
    initialisation ([let () = init ()] at EOF runs before any Eio
    scheduler exists), must hold across OCaml 5 domains (Executor_pool
    workers), and are individually cheap (a Hashtbl op + a float add) so
    the lock is never held long. [Stdlib.Mutex] fits all three. *)

let metrics : (string, metric) Hashtbl.t = Hashtbl.create 64
let metrics_mutex = Stdlib.Mutex.create ()

let with_lock f =
  Stdlib.Mutex.lock metrics_mutex;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock metrics_mutex)
    f

(** {1 Metric Registration} *)

let register_counter ~name ~help ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels })

let register_gauge ~name ~help ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels })

let register_histogram ~name ~help ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Histogram; value = 0.0; labels })

(** {1 Metric Updates} *)

let inc_counter name ?(labels=[]) ?(delta=1.0) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- m.value +. delta
    | None ->
        Hashtbl.add metrics key {
          name;
          help = name;
          metric_type = Counter;
          value = delta;
          labels;
        })

let set_gauge name ?(labels=[]) value =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- value
    | None ->
        Hashtbl.add metrics key {
          name;
          help = name;
          metric_type = Gauge;
          value;
          labels;
        })

let inc_gauge name ?(labels=[]) ?(delta=1.0) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    match Hashtbl.find_opt metrics key with
    | Some m -> m.value <- m.value +. delta
    | None ->
        Hashtbl.add metrics key {
          name;
          help = name;
          metric_type = Gauge;
          value = delta;
          labels;
        })

let dec_gauge name ?(labels=[]) ?(delta=1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()

(** Get current metric value by name + labels (if any). *)
let get_metric_value name ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    Hashtbl.find_opt metrics key |> Option.map (fun m -> m.value))

let metric_value_or_zero name ?(labels=[]) () =
  get_metric_value name ~labels () |> Option.value ~default:0.0

(** Observe a histogram value.
    Tracks cumulative sum in the metric value; a matching _count counter
    is auto-created for computing averages. *)
let observe_histogram name ?(labels=[]) value =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  let count_key = name ^ "_count" ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  with_lock (fun () ->
    (match Hashtbl.find_opt metrics key with
     | Some m -> m.value <- m.value +. value
     | None ->
         Hashtbl.add metrics key {
           name; help = name; metric_type = Histogram; value; labels;
         });
    (match Hashtbl.find_opt metrics count_key with
     | Some m -> m.value <- m.value +. 1.0
     | None ->
         Hashtbl.add metrics count_key {
           name = name ^ "_count"; help = name ^ " observation count";
           metric_type = Counter; value = 1.0; labels;
         }))

(** {1 Metric Name Constants}

    Exported so registration here and [inc_counter] call-sites in
    [keeper_unified_turn.ml] share a single source of truth. Without
    this, a typo on either side produces a dead series with no build
    error (the counter silently drifts to a new key).

    Follow-up #7469 Step 1: only the cache counters are covered — the
    existing input/output/turns counters still use inline strings and
    should migrate in a separate pass to keep this PR surgical. *)

let metric_keeper_cache_creation_tokens =
  "masc_keeper_cache_creation_tokens_total"

let metric_keeper_cache_read_tokens =
  "masc_keeper_cache_read_tokens_total"

(** {1 Built-in Metrics} *)

let init () =
  (* Module-level init runs before Eio context exists.
     Single-threaded at load time — bypass mutex. *)
  let add name help mt =
    let key = name in
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = mt; value = 0.0; labels = [] }
  in
  add "masc_mcp_requests_total" "Total MCP requests received" Counter;
  add "masc_llm_inference_duration_seconds" "LLM inference request duration in seconds" Histogram;
  add "masc_after_turn_hook_total"
    "Times the keeper AfterTurn hook ran (labeled by model). Divergence from \
     masc_llm_inference_duration_seconds_count identifies missing telemetry." Counter;
  add "masc_after_turn_telemetry_missing_total"
    "AfterTurn responses where response.telemetry was None." Counter;
  add "masc_after_turn_telemetry_zero_latency_total"
    "AfterTurn responses where telemetry was present but request_latency_ms was 0." Counter;
  add "masc_tasks_total" "Total tasks processed" Counter;
  add "masc_errors_total" "Total errors" Counter;
  add "masc_active_agents" "Currently active agents" Gauge;
  add "masc_pending_tasks" "Tasks waiting to be claimed" Gauge;
  add "masc_uptime_seconds" "Server uptime in seconds" Gauge;
  add "masc_sse_connections_active" "Active SSE connections" Gauge;
  add "masc_sse_reconnects_total" "Total SSE reconnects (same session reattached)" Counter;
  add "masc_sse_idle_evictions_total" "Total SSE clients evicted by idle reaper" Counter;
  add "masc_sse_capacity_evictions_total" "Total SSE clients evicted due to max client capacity" Counter;
  add "masc_sse_write_failures_total" "Total SSE write failures by reason" Counter;
  add "masc_sse_rejects_total" "Total SSE connections rejected by storm guard" Counter;
  (* Keeper compaction metrics — emitted by keeper_compact_policy.ml *)
  add "masc_keeper_compactions_total"
    "Total keeper compactions performed" Counter;
  add "masc_keeper_compaction_ratio_change"
    "Context ratio change after compaction (pre - post)" Gauge;
  (* Operator-initiated overflow recovery — emitted by tool_keeper.ml *)
  add "masc_keeper_operator_compact_total"
    "Total operator-invoked masc_keeper_compact calls (labels: result=ok|no_checkpoint|precondition|not_found)" Counter;
  add "masc_keeper_operator_clear_total"
    "Total operator-invoked masc_keeper_clear calls (labels: preserve_system=true|false)" Counter;
  (* Keeper heartbeat metrics — emitted by keeper_keepalive.ml *)
  add "masc_keeper_heartbeat_successes_total"
    "Total keeper heartbeat successes" Counter;
  add "masc_keeper_heartbeat_failures_total"
    "Total keeper heartbeat failures" Counter;
  add "masc_provider_prefix_cache_creation_tokens_total"
    "Total provider prefix cache creation tokens (Anthropic)" Counter;
  add "masc_provider_prefix_cache_read_tokens_total"
    "Total provider prefix cache read tokens (Anthropic)" Counter;
  register_histogram ~name:"masc_tool_call_duration_seconds"
    ~help:"Tool call latency in seconds" ();
  (* Inference admission queue metrics *)
  add "masc_inference_queue_inflight"
    "Concurrent inference calls holding an admission permit" Gauge;
  add "masc_inference_queue_depth"
    "Callers waiting in the admission queue" Gauge;
  add "masc_inference_queue_max_concurrent"
    "Configured max concurrent admission permits" Gauge;
  add "masc_inference_queue_acquired_total"
    "Total admission permits acquired" Counter;
  add "masc_inference_queue_cancelled_total"
    "Total admission waits cancelled by fiber cancellation" Counter;
  register_histogram ~name:"masc_inference_queue_wait_seconds"
    ~help:"Time waiting in admission queue before exchanging for permit" ();
  (* LLM provider HTTP response counter — emitted by Llm_metric_bridge
     via the OAS Metrics.t on_http_status hook.  Labels are populated
     dynamically per call; no initial registration with zero-value rows
     is needed because inc_counter auto-creates the label series on
     first observation. *)
  add "masc_llm_provider_http_status_total"
    "Total HTTP responses from LLM providers, labeled by provider, model, and status code"
    Counter;
  (* Orphan metrics — used via inc_counter/set_gauge but previously
     never registered.  Auto-create still works, but registering here
     gives them a HELP description in /metrics output and a zero-value
     baseline so dashboards see "0" instead of "no data" before the
     first observation. *)
  add "masc_keeper_write_meta_failures_total"
    "Total keeper meta-file write failures, labeled by keeper and phase"
    Counter;
  add "masc_keeper_collision_detected_total"
    "Total keeper-name collision detections during evidence assembly"
    Counter;
  add "masc_board_truncated_posts_total"
    "Total board posts truncated due to size limits"
    Counter;
  add "masc_agent_heartbeat_age_seconds"
    "Maximum observed heartbeat age across active agents (seconds)"
    Gauge;
  add "masc_agent_stale_total"
    "Total agents marked stale due to missed heartbeats"
    Counter;
  register_histogram ~name:"masc_llm_provider_request_latency_seconds"
    ~help:"Per-HTTP-request LLM latency from OAS on_request_end callback. \
           Independent from masc_llm_inference_duration_seconds (turn-scope) — \
           this fires per provider HTTP call regardless of keeper hook health." ();
  (* Process-level resource gauges.  Sampled on every /metrics scrape via
     [update_fd_gauges] so a monotonic ramp (fd leak) is visible in the
     time series before it crosses the OS limit and crashes the server.
     Evidence: 2026-04-16 production incident, 4029 CLOSE_WAIT sockets
     accumulated before the accept() path started failing. *)
  let fd_open = "masc_process_open_fds" in
  let fd_threshold = "masc_process_fd_warn_threshold" in
  add fd_open
    "Approximate count of open file descriptors for the server process \
     (derived from /dev/fd). Ramp indicates a socket/file leak." Gauge;
  add fd_threshold
    "Threshold above which open_fds triggers a one-shot WARN log." Gauge;
  set_gauge fd_threshold
    (float_of_int (Env_config_core.get_int ~default:3000 "MASC_FD_WARN_THRESHOLD" |> max 1));
  (* Per-keeper turn outcome + token counters.  Labels are populated
     dynamically via inc_counter; no upfront registration needed.
     Covers issues #7495 (cost/token attribution) and #7519 (SLO). *)
  add "masc_keeper_turns_total"
    "Total keeper turns by outcome (labels: keeper_name, outcome=success|failure|budget_exhausted|mutation_boundary)"
    Counter;
  add "masc_keeper_input_tokens_total"
    "Cumulative input tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  add "masc_keeper_output_tokens_total"
    "Cumulative output tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  (* Anthropic / Bedrock prompt caching observability (#7469 Step 1).
     OAS already receives [cache_creation_input_tokens] and
     [cache_read_input_tokens] in every [api_usage]; these counters
     expose them to Prometheus so cache hit-rate and write cost are
     attributable per keeper + model. Populated dynamically via
     [inc_counter]; tools that never emit cache data (e.g. non-Anthropic
     providers) simply leave these at 0. Names are exported as module
     constants below so registration and call-sites cannot drift. *)
  add metric_keeper_cache_creation_tokens
    "Cumulative prompt-cache creation tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  add metric_keeper_cache_read_tokens
    "Cumulative prompt-cache read tokens per keeper turn (labels: keeper_name, model)"
    Counter;
  (* Tool schema budget gauges — set once at boot via
     [set_tool_schema_stats]. Covers #7483 Step 1. *)
  add "masc_mcp_tool_schema_count"
    "Number of tool schemas exposed to MCP clients" Gauge;
  add "masc_mcp_tool_schema_tokens_approx"
    "Approximate token count of all tool schemas combined (chars/4)"
    Gauge

let metric_open_fds = "masc_process_open_fds"

let start_time = Time_compat.now ()

let update_uptime () =
  set_gauge "masc_uptime_seconds" (Time_compat.now () -. start_time)

let fd_warn_threshold =
  Env_config_core.get_int ~default:3000 "MASC_FD_WARN_THRESHOLD" |> max 1

let fd_warned_once = ref false

(** Returns 0 on non-Unix hosts where [/dev/fd] is unavailable. *)
let approximate_open_fd_count () =
  let candidates = ["/dev/fd"; "/proc/self/fd"] in
  let rec first_readable = function
    | [] -> None
    | path :: rest ->
        (try Some (path, Sys.readdir path)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | _exn -> first_readable rest)
  in
  match first_readable candidates with
  | None -> 0
  | Some (_path, entries) ->
      max 0 (Array.length entries - 1)

let update_fd_gauges () =
  let count = approximate_open_fd_count () in
  set_gauge metric_open_fds (float_of_int count);
  if count >= fd_warn_threshold && not !fd_warned_once then begin
    fd_warned_once := true;
    Printf.eprintf
      "[WARN] [Server] process open fd count %d has reached warn \
       threshold %d — likely socket/file leak, investigate before \
       accept() starts failing with EMFILE.\n%!"
      count fd_warn_threshold
  end else if count < fd_warn_threshold / 2 then
    fd_warned_once := false

let set_tool_schema_stats ~count ~approx_tokens =
  set_gauge "masc_mcp_tool_schema_count" (float_of_int count);
  set_gauge "masc_mcp_tool_schema_tokens_approx" (float_of_int approx_tokens)

(** {1 Prometheus Export} *)

let type_to_string = function
  | Counter -> "counter"
  | Gauge -> "gauge"
  | Histogram -> "histogram"

let labels_to_string = function
  | [] -> ""
  | labels ->
      let pairs = List.map (fun (k, v) ->
        Printf.sprintf "%s=\"%s\"" k (String.escaped v)
      ) labels in
      "{" ^ String.concat "," pairs ^ "}"

let to_prometheus_text () =
  update_uptime ();
  update_fd_gauges ();
  (* Snapshot (name, help, metric_type, value, labels) under the mutex so
     the render phase sees a consistent view even when concurrent fibers
     are still updating [metrics].  [m.value] is mutable so we copy it
     here rather than holding the lock for the full render. *)
  let snapshot =
    with_lock (fun () ->
      Hashtbl.fold
        (fun _ (m : metric) acc ->
          { name = m.name;
            help = m.help;
            metric_type = m.metric_type;
            value = m.value;
            labels = m.labels;
          } :: acc)
        metrics [])
  in
  let buf = Buffer.create 1024 in
  let by_name = Hashtbl.create 32 in
  List.iter (fun (m : metric) ->
    let existing = Hashtbl.find_opt by_name m.name |> Option.value ~default:[] in
    Hashtbl.replace by_name m.name (m :: existing)
  ) snapshot;
  (* Collect histogram parent names.  observe_histogram stores the
     cumulative sum under the original name and the observation count
     under "<name>_count".  We suppress standalone export of the
     _count companion and instead emit it inline as part of the
     summary stanza for the parent. *)
  let histogram_parents = Hashtbl.create 8 in
  Hashtbl.iter (fun name ms ->
    List.iter (fun (m : metric) ->
      if m.metric_type = Histogram then
        Hashtbl.replace histogram_parents name true
    ) ms
  ) by_name;
  let label_key labels =
    String.concat "" (List.map (fun (k, v) -> k ^ v) labels)
  in
  Hashtbl.iter (fun name ms ->
    let is_histogram_count =
      let suf = "_count" in
      let slen = String.length suf in
      String.length name > slen
      && String.sub name (String.length name - slen) slen = suf
      && Hashtbl.mem histogram_parents
           (String.sub name 0 (String.length name - slen))
    in
    if is_histogram_count then ()
    else
    match ms with
    | [] -> ()
    | m :: _ ->
      Buffer.add_string buf (Printf.sprintf "# HELP %s %s\n" name m.help);
      (match m.metric_type with
       | Histogram ->
         (* No bucket distribution is tracked, so emit as summary
            (sum + count) which is the closest valid Prometheus type. *)
         Buffer.add_string buf (Printf.sprintf "# TYPE %s summary\n" name);
         List.iter (fun (metric : metric) ->
           let ls = labels_to_string metric.labels in
           Buffer.add_string buf
             (Printf.sprintf "%s_sum%s %g\n" name ls metric.value);
           let count_key = name ^ "_count" ^ label_key metric.labels in
           let count_val =
             with_lock (fun () ->
               match Hashtbl.find_opt metrics count_key with
               | Some cm -> cm.value
               | None -> 0.0)
           in
           Buffer.add_string buf
             (Printf.sprintf "%s_count%s %g\n" name ls count_val)
         ) ms
       | _ ->
         Buffer.add_string buf
           (Printf.sprintf "# TYPE %s %s\n" name (type_to_string m.metric_type));
         List.iter (fun (metric : metric) ->
           Buffer.add_string buf (Printf.sprintf "%s%s %g\n"
             metric.name (labels_to_string metric.labels) metric.value)
         ) ms)
  ) by_name;
  Buffer.contents buf

(** {1 Convenience Functions} *)

let record_request () =
  inc_counter "masc_mcp_requests_total" ()

let record_task_completed () =
  inc_counter "masc_tasks_total" ~labels:[("status", "completed")] ()

let record_task_failed () =
  inc_counter "masc_tasks_total" ~labels:[("status", "failed")] ()

let record_error ?(error_type="unknown") () =
  inc_counter "masc_errors_total" ~labels:[("type", error_type)] ()

let set_active_agents count =
  set_gauge "masc_active_agents" (float_of_int count)

let set_pending_tasks count =
  set_gauge "masc_pending_tasks" (float_of_int count)

(** Reconcile active_agents gauge with existing agent files on disk.
    Call after Coord/server initialization to sync Prometheus state. *)
let reconcile_active_agents_gauge masc_dir =
  let agents_dir = Filename.concat masc_dir "agents" in
  if Sys.file_exists agents_dir && Sys.is_directory agents_dir then
    let files = Sys.readdir agents_dir in
    let count = Array.fold_left (fun acc f ->
      if Filename.check_suffix f ".json" then acc + 1 else acc
    ) 0 files in
    set_active_agents count

(** Initialize on module load *)
let () = init ()
