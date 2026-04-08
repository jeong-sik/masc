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

(** {1 Global Metrics Store} *)

let metrics : (string, metric) Hashtbl.t = Hashtbl.create 64

(** {1 Metric Registration} *)

let register_counter ~name ~help ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  if not (Hashtbl.mem metrics key) then
    Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels }

let register_gauge ~name ~help ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  if not (Hashtbl.mem metrics key) then
    Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels }

let register_histogram ~name ~help ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  if not (Hashtbl.mem metrics key) then
    Hashtbl.add metrics key { name; help; metric_type = Histogram; value = 0.0; labels }

(** {1 Metric Updates} *)

let inc_counter name ?(labels=[]) ?(delta=1.0) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  match Hashtbl.find_opt metrics key with
  | Some m -> m.value <- m.value +. delta
  | None ->
      Hashtbl.add metrics key {
        name;
        help = name;
        metric_type = Counter;
        value = delta;
        labels;
      }

let set_gauge name ?(labels=[]) value =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  match Hashtbl.find_opt metrics key with
  | Some m -> m.value <- value
  | None ->
      Hashtbl.add metrics key {
        name;
        help = name;
        metric_type = Gauge;
        value;
        labels;
      }

let inc_gauge name ?(labels=[]) ?(delta=1.0) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  match Hashtbl.find_opt metrics key with
  | Some m -> m.value <- m.value +. delta
  | None ->
      Hashtbl.add metrics key {
        name;
        help = name;
        metric_type = Gauge;
        value = delta;
        labels;
      }

let dec_gauge name ?(labels=[]) ?(delta=1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()

(** Get current metric value by name + labels (if any). *)
let get_metric_value name ?(labels=[]) () =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  Hashtbl.find_opt metrics key |> Option.map (fun m -> m.value)

let metric_value_or_zero name ?(labels=[]) () =
  get_metric_value name ~labels () |> Option.value ~default:0.0

(** Observe a histogram value.
    Tracks cumulative sum in the metric value; a matching _count counter
    is auto-created for computing averages. *)
let observe_histogram name ?(labels=[]) value =
  let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
  let count_key = name ^ "_count" ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
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
      })

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
  (* Delta checkpoint metrics *)
  add "masc_delta_shadow_match_total"
    "Shadow-apply delta: rebuilt hash matches current checkpoint" Counter;
  add "masc_delta_shadow_mismatch_total"
    "Shadow-apply delta: rebuilt hash differs from current checkpoint" Counter;
  add "masc_delta_shadow_error_total"
    "Shadow-apply delta: compute or apply raised an error" Counter;
  register_histogram ~name:"masc_delta_checkpoint_size_bytes"
    ~help:"Size in bytes of serialized delta checkpoint" ();
  register_histogram ~name:"masc_full_checkpoint_size_bytes"
    ~help:"Size in bytes of serialized full checkpoint" ();
  register_gauge ~name:"masc_delta_size_ratio"
    ~help:"Ratio of delta size to full checkpoint size (last observation)" ();
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
    ~help:"Time waiting in admission queue before acquiring permit" ()

let start_time = Time_compat.now ()

let update_uptime () =
  set_gauge "masc_uptime_seconds" (Time_compat.now () -. start_time)

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
  let buf = Buffer.create 1024 in
  let by_name = Hashtbl.create 32 in
  Hashtbl.iter (fun _ m ->
    let existing = Hashtbl.find_opt by_name m.name |> Option.value ~default:[] in
    Hashtbl.replace by_name m.name (m :: existing)
  ) metrics;
  Hashtbl.iter (fun name ms ->
    match ms with
    | [] -> ()
    | m :: _ ->
        Buffer.add_string buf (Printf.sprintf "# HELP %s %s\n" name m.help);
        Buffer.add_string buf (Printf.sprintf "# TYPE %s %s\n" name (type_to_string m.metric_type));
        List.iter (fun metric ->
          Buffer.add_string buf (Printf.sprintf "%s%s %g\n"
            metric.name
            (labels_to_string metric.labels)
            metric.value)
        ) ms
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
    Call after Room/server initialization to sync Prometheus state. *)
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
