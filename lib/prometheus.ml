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
let metrics_mutex = Eio.Mutex.create ()

let with_lock f =
  Eio.Mutex.use_rw ~protect:true metrics_mutex (fun () -> f ())

(** {1 Metric Registration} *)

let register_counter ~name ~help ?(labels=[]) () =
  with_lock (fun () ->
    let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Counter; value = 0.0; labels }
  )

let register_gauge ~name ~help ?(labels=[]) () =
  with_lock (fun () ->
    let key = name ^ (String.concat "" (List.map (fun (k, v) -> k ^ v) labels)) in
    if not (Hashtbl.mem metrics key) then
      Hashtbl.add metrics key { name; help; metric_type = Gauge; value = 0.0; labels }
  )

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
        }
  )

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
        }
  )

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
        }
  )

let dec_gauge name ?(labels=[]) ?(delta=1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()

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
  add "masc_sse_write_failures_total" "Total SSE write failures by reason" Counter

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
  with_lock (fun () ->
    Hashtbl.iter (fun _ m ->
      let existing = Hashtbl.find_opt by_name m.name |> Option.value ~default:[] in
      Hashtbl.replace by_name m.name (m :: existing)
    ) metrics
  );
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

(** Initialize on module load *)
let () = init ()
