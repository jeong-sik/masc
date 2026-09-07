(** MASC Telemetry - event tracking and analytics on date-split JSONL. *)


(** Config type alias *)
type config = Workspace_utils.config

(** Tool-call error classification labels. *)
type error_kind = Error_kind of string

let error_kind_of_string value = Error_kind value
let error_kind_to_string (Error_kind value) = value
let error_kind_to_yojson kind = `String (error_kind_to_string kind)

let error_kind_of_yojson = function
  | `String value -> Ok (error_kind_of_string value)
  | json ->
      Error
        (Printf.sprintf "Telemetry_eio.error_kind: expected string, got %s"
           (Yojson.Safe.to_string json))

let pp_error_kind fmt kind =
  Format.pp_print_string fmt (error_kind_to_string kind)

(** Telemetry event types *)
type event =
  | Agent_session_bound of { agent_id: string; capabilities: string list }
  | Agent_unbound of { agent_id: string; reason: string }
  | Task_started of { task_id: string; agent_id: string }
  | Task_completed of { task_id: string; duration_ms: int; success: bool }
  | Error_occurred of { code: string; message: string; context: string }
  | Tool_called of {
      tool_name: string;
      success: bool;
      duration_ms: int;
      agent_id: string option [@default None];
      source: string option [@default None];
      session_id: string option [@default None];
      operation_id: string option [@default None];
      worker_run_id: string option [@default None];
      (* RFC-0233 canonical join key, minted once at the dispatch boundary.
         The tool_calls row for the same execution carries the identical
         value, so a consumer reading both streams can tell one physical
         call reported twice from two calls. [None] on lanes that write no
         tool_calls row — nothing there is a duplicate to begin with. *)
      execution_id: string option [@default None];
      error_kind: error_kind option [@default None];
      error_message: string option [@default None];
      exit_code: int option [@default None];
      stderr_excerpt: string option [@default None];
      (* Typed failure classification preserved alongside [success].
         [success = false] without a [failure_class] is now an
         observable gap — downstream consumers (telemetry_unified
         dedupe, dashboard attribution) can stop reconstructing the
         class from [error_message] substrings.  RFC-0088 §1 root-fix
         seam for the "Tool_called row carries no typed failure_class"
         finding (PR-6).  Producer migration that actually populates
         this field for every error path is tracked separately so this
         introduction PR keeps the record-shape change surgical. *)
      failure_class: Tool_result.tool_failure_class option [@default None];
    }
  | Tool_assigned of {
      agent_id: string;
      profile: string;
      tool_count: int;
      assignment_id: string;
    }
[@@deriving yojson, show]

(** Timestamped event record for storage *)
type event_record = {
  timestamp: float;
  event: event;
} [@@deriving yojson, show]

type tool_usage_stats = {
  count: int;
  success_count: int;
  failure_count: int;
  last_used_at: float option;
}

type tool_usage_summary = {
  telemetry_path: string;
  telemetry_available: bool;
  total_calls: int;
  stats_by_tool: (string, tool_usage_stats) Hashtbl.t;
}

let empty_tool_usage_stats = {
  count = 0;
  success_count = 0;
  failure_count = 0;
  last_used_at = None;
}

let update_tool_usage stats_by_tool ~tool_name ~success ~timestamp =
  let current =
    match Hashtbl.find_opt stats_by_tool tool_name with
    | Some stats -> stats
    | None -> empty_tool_usage_stats
  in
  let updated = {
    count = current.count + 1;
    success_count = current.success_count + (if success then 1 else 0);
    failure_count = current.failure_count + (if success then 0 else 1);
    last_used_at =
      Some
        (match current.last_used_at with
        | Some previous -> max previous timestamp
        | None -> timestamp);
  } in
  Hashtbl.replace stats_by_tool tool_name updated

(** Date-split store: [.masc/telemetry/YYYY-MM/DD.jsonl].
    Cached per base_dir so all callers share the same Eio.Mutex.
    See audit_log.ml get_audit_store for the invariant rationale. *)
let telemetry_store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4
let telemetry_store_cache_mu = Eio.Mutex.create ()

let telemetry_retention_days_env = "MASC_TELEMETRY_RETENTION_DAYS"
let telemetry_max_bytes_env = "MASC_TELEMETRY_MAX_BYTES"
let default_telemetry_retention_days = 30
let default_telemetry_max_bytes = 52_428_800

let positive_int_env_with_default key ~default =
  match Sys.getenv_opt key with
  | None -> Some default
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some value when value > 0 -> Some value
     | Some _ -> None
     | None -> Some default)

let telemetry_retention_days () =
  positive_int_env_with_default telemetry_retention_days_env
    ~default:default_telemetry_retention_days

let telemetry_max_bytes () =
  positive_int_env_with_default telemetry_max_bytes_env
    ~default:default_telemetry_max_bytes

let get_telemetry_store config : Dated_jsonl.t =
  let base = Filename.concat (Workspace_utils.masc_dir config) "telemetry" in
  Eio_guard.with_mutex telemetry_store_cache_mu (fun () ->
    match Hashtbl.find_opt telemetry_store_cache base with
    | Some store -> store
    | None ->
      let retention_days = telemetry_retention_days () in
      let max_bytes = telemetry_max_bytes () in
      let store =
        Dated_jsonl.create ~base_dir:base ?retention_days ?max_bytes ()
      in
      Hashtbl.replace telemetry_store_cache base store;
      store)

let telemetry_eio_surface = "telemetry_eio"

let observe_telemetry_drop ~reason =
  Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
    ~labels:[ ("surface", telemetry_eio_surface); ("reason", reason) ]
    ()

let report_telemetry_drop ~reason ~path ~detail =
  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () -> observe_telemetry_drop ~reason:reason_wire)
    ~surface:telemetry_eio_surface ~reason ~path ~detail

(* Per-row decode. Reporting a drop only logs and bumps a counter, with no
   quota or early stop, so this is safe to run under a newest-first scan. *)
let parse_event_record (json : Yojson.Safe.t) : event_record option =
  match event_record_of_yojson json with
  | Ok record -> Some record
  | Error msg ->
      report_telemetry_drop
        ~reason:Read_drop_reason.Invalid_payload
        ~path:"<in-memory>" ~detail:msg;
      None

let parse_event_records (jsons : Yojson.Safe.t list) : event_record list =
  List.filter_map parse_event_record jsons

let event_to_json event =
  let record = {
    timestamp = Time_compat.now ();
    event;
  } in
  event_record_to_yojson record

(** Track an event - appends to date-split telemetry store.
    Thread-safe via Dated_jsonl internal mutex. *)
let track ?fs:_ config event : unit =
  let store = get_telemetry_store config in
  Dated_jsonl.append store (event_to_json event)

(** Read all current date-split events. *)
let read_all_events ?fs:_ config : event_record list =
  let store = get_telemetry_store config in
  Dated_jsonl.filter_map_recent store 100_000 ~f:parse_event_record

(* ── Tool usage summary cache ──────────────────────────────────────
   The dashboard refreshes Tool Monitor / Fleet Health / Tool Quality
   surfaces every 30 s. Each surface calls [summarize_tool_usage] on
   the same store, opening and counting every day-file. With 30
   day-files × 15 MB this becomes a hot read-side load.
   Cache TTL matches the dashboard refresh interval. *)

type tool_usage_cache_entry = {
  cached_summary : tool_usage_summary;
  cached_at : float;
}

let tool_usage_cache : tool_usage_cache_entry option Atomic.t = Atomic.make None
let tool_usage_cache_ttl = 30.0  (* seconds *)

let summarize_tool_usage ?fs config : tool_usage_summary =
  let now = Time_compat.now () in
  match Atomic.get tool_usage_cache with
  | Some entry when now -. entry.cached_at < tool_usage_cache_ttl ->
      entry.cached_summary
  | _ ->
      let store = get_telemetry_store config in
      let telemetry_path = Dated_jsonl.base_dir store in
      let telemetry_available = Sys.file_exists telemetry_path in
      let stats_by_tool = Hashtbl.create 32 in
      let total_calls = ref 0 in
      let records = read_all_events ?fs config in
      List.iter (fun (record : event_record) ->
        match record.event with
        | Tool_called { tool_name; success; _ } ->
            incr total_calls;
            update_tool_usage stats_by_tool ~tool_name ~success
              ~timestamp:record.timestamp
        | Agent_session_bound _ | Agent_unbound _ | Task_started _ | Task_completed _
        | Error_occurred _ | Tool_assigned _ -> ()
      ) records;
      let summary = {
        telemetry_path;
        telemetry_available;
        total_calls = !total_calls;
        stats_by_tool;
      } in
      Atomic.set tool_usage_cache (Some { cached_summary = summary; cached_at = now });
      summary

(** Agent activity summary from telemetry, filtered by time window. *)
type agent_activity = {
  agent_id: string;
  tool_calls: int;
  success_count: int;
  failure_count: int;
  first_seen: float;
  last_seen: float;
}

let summarize_agent_activity ?fs config ~since : agent_activity list =
  let records = read_all_events ?fs config in
  let by_agent : (string, agent_activity) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (record : event_record) ->
    if record.timestamp >= since then
      match record.event with
      | Tool_called { agent_id = Some aid; success; _ } ->
          let current =
            match Hashtbl.find_opt by_agent aid with
            | Some a -> a
            | None -> { agent_id = aid; tool_calls = 0; success_count = 0;
                        failure_count = 0; first_seen = record.timestamp;
                        last_seen = record.timestamp }
          in
          Hashtbl.replace by_agent aid
            { current with
              tool_calls = current.tool_calls + 1;
              success_count = current.success_count + (if success then 1 else 0);
              failure_count = current.failure_count + (if success then 0 else 1);
              first_seen = min current.first_seen record.timestamp;
              last_seen = max current.last_seen record.timestamp;
            }
      | Tool_called { agent_id = None; _ } -> ()
      | Agent_session_bound { agent_id; _ } ->
          if not (Hashtbl.mem by_agent agent_id) then
            Hashtbl.replace by_agent agent_id
              { agent_id; tool_calls = 0; success_count = 0; failure_count = 0;
                first_seen = record.timestamp; last_seen = record.timestamp }
      | Agent_unbound _ | Task_started _ | Task_completed _ | Error_occurred _
      | Tool_assigned _ -> ()
  ) records;
  Hashtbl.fold (fun _ v acc -> v :: acc) by_agent []
  |> List.sort (fun a b -> compare b.tool_calls a.tool_calls)

let tool_usage_fields summary tool_name =
  let stats =
    match Hashtbl.find_opt summary.stats_by_tool tool_name with
    | Some stats -> stats
    | None -> empty_tool_usage_stats
  in
  [
    ("usageCount", `Int stats.count);
    ("usageSuccessCount", `Int stats.success_count);
    ("usageFailureCount", `Int stats.failure_count);
    ("usageLastUsedAt",
     match stats.last_used_at with
     | Some timestamp -> `Float timestamp
     | None -> `Null);
  ]

(** Metrics calculation functions (pure) *)

(* [count_active_agents] = session_bound \ left,
   [count_tasks_in_progress] = started \ completed.
   Kernel lives in [Set_util.count_difference] (lib/core/set_util.ml). *)
let count_active_agents events =
  Set_util.count_difference events
    ~present:(fun r ->
      match r.event with
      | Agent_session_bound { agent_id; _ } -> Some agent_id
      | Agent_unbound _ | Task_started _ | Task_completed _ | Error_occurred _
      | Tool_called _ | Tool_assigned _ -> None)
    ~absent:(fun r ->
      match r.event with
      | Agent_unbound { agent_id; _ } -> Some agent_id
      | Agent_session_bound _ | Task_started _ | Task_completed _ | Error_occurred _
      | Tool_called _ | Tool_assigned _ -> None)

let count_tasks_in_progress events =
  Set_util.count_difference events
    ~present:(fun r ->
      match r.event with
      | Task_started { task_id; _ } -> Some task_id
      | Agent_session_bound _ | Agent_unbound _ | Task_completed _ | Error_occurred _
      | Tool_called _ | Tool_assigned _ -> None)
    ~absent:(fun r ->
      match r.event with
      | Task_completed { task_id; _ } -> Some task_id
      | Agent_session_bound _ | Agent_unbound _ | Task_started _ | Error_occurred _
      | Tool_called _ | Tool_assigned _ -> None)

let count_completed_tasks events =
  List_util.count_if (fun r ->
    match r.event with
    | Task_completed _ -> true
    | Agent_session_bound _ | Agent_unbound _ | Task_started _ | Error_occurred _
    | Tool_called _ | Tool_assigned _ -> false
  ) events

let avg_duration events =
  let durations = List.filter_map (fun r ->
    match r.event with
    | Task_completed { duration_ms; _ } -> Some (float_of_int duration_ms)
    | Agent_session_bound _ | Agent_unbound _ | Task_started _ | Error_occurred _
    | Tool_called _ | Tool_assigned _ -> None
  ) events in
  match durations with
  | [] -> 0.0
  | times ->
      let sum = List.fold_left (+.) 0.0 times in
      sum /. float_of_int (List.length times)

let calculate_error_rate events =
  let errors = List_util.count_if (fun r ->
    match r.event with
    | Error_occurred _ -> true
    | Agent_session_bound _ | Agent_unbound _ | Task_started _ | Task_completed _
    | Tool_called _ | Tool_assigned _ -> false
  ) events in
  let total = List.length events in
  if total = 0 then 0.0
  else float_of_int errors /. float_of_int total

(** Convenience tracking functions *)
let track_agent_session_bound ?fs config ~agent_id ?(capabilities=[]) () =
  track ?fs config (Agent_session_bound { agent_id; capabilities })

let track_agent_unbound ?fs config ~agent_id ~reason =
  track ?fs config (Agent_unbound { agent_id; reason })

let track_task_started ?fs config ~task_id ~agent_id =
  track ?fs config (Task_started { task_id; agent_id })

let track_task_completed ?fs config ~task_id ~duration_ms ~success =
  track ?fs config (Task_completed { task_id; duration_ms; success })

let track_error ?fs config ~code ~message ~context =
  track ?fs config (Error_occurred { code; message; context })

(** #10358: persist classified tool-call failure diagnostics and
    emit paired [Error_occurred] rows for callers that provide an
    [error_kind]. All diagnostic fields are additive/nullable. *)
let nonempty_opt value =
  match value with
  | Some s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | None -> None

let nonempty_error_kind_opt value =
  match value with
  | Some kind ->
      let trimmed = String.trim (error_kind_to_string kind) in
      if trimmed = "" then None else Some (error_kind_of_string trimmed)
  | None -> None

let track_tool_called ?fs config ~tool_name ~success ~duration_ms ?agent_id
    ?source ?session_id ?operation_id ?worker_run_id ?execution_id
    ?failure_class ?error_kind
    ?error_message ?exit_code ?stderr_excerpt () =
  let failure_class = if success then None else failure_class in
  let error_kind =
    if success then None else nonempty_error_kind_opt error_kind
  in
  let error_message = if success then None else nonempty_opt error_message in
  let exit_code = if success then None else exit_code in
  let stderr_excerpt =
    if success then None else nonempty_opt stderr_excerpt
  in
  track ?fs config
    (Tool_called
       {
         tool_name;
         success;
         duration_ms;
         agent_id;
         source;
         session_id;
         operation_id;
         worker_run_id;
         execution_id;
         error_kind;
         error_message;
         exit_code;
         stderr_excerpt;
         failure_class;
       });
  if not success then
    match error_kind with
    | None -> ()
    | Some kind ->
          let trimmed_kind = error_kind_to_string kind in
          let message =
            match error_message with
            | Some m -> m
            | _ ->
                Printf.sprintf "tool %s failed (%s)" tool_name
                  trimmed_kind
          in
          let context_parts =
            List.filter_map
              (fun (k, v) ->
                match v with
                | Some s when String.trim s <> "" ->
                    Some (Printf.sprintf "%s=%s" k s)
                | _ -> None)
              [
                ("tool", Some tool_name);
                ("agent", agent_id);
                ("source", source);
                ("session", session_id);
                ("op", operation_id);
              ]
          in
          let context = String.concat " " context_parts in
          track ?fs config
            (Error_occurred { code = trimmed_kind; message; context })
