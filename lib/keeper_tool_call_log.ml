(** Keeper_tool_call_log — Full I/O logging for keeper tool calls.

    Persists complete tool call records (input arguments + output text)
    to [.masc/tool_calls/YYYY-MM/DD.jsonl] via {!Dated_jsonl}.

    Unlike {!Tool_usage_log} (metadata only) and {!Tool_metrics_persist}
    (aggregated counts), this module stores the actual I/O for debugging
    and dashboard inspection.

    Output is truncated to {!max_output_len} bytes to prevent disk
    explosion from large tool results (e.g. full file reads).

    @since 2.249.0 — Keeper observability *)

let max_output_len = 4000

(** Pre-truncation info, keyed by keeper name.
    Set by the tool handler wrapper (keeper_tools_oas), consumed by the
    OAS on_tool_result hook (keeper_hooks_oas).  Per-keeper isolation
    prevents cross-keeper corruption when multiple keepers call tools
    concurrently. Within a single keeper's Agent.run, tool calls are
    sequential so set→consume ordering is guaranteed. *)
let pending_truncation : (string, int * int option) Hashtbl.t = Hashtbl.create 8

let set_truncation_info ~keeper_name ~original_bytes ?truncated_to () =
  Hashtbl.replace pending_truncation keeper_name (original_bytes, truncated_to)
;;

let consume_truncation_info ~keeper_name () =
  match Hashtbl.find_opt pending_truncation keeper_name with
  | Some info ->
    Hashtbl.remove pending_truncation keeper_name;
    info
  | None -> 0, None
;;

type turn_ctx_cell = Keeper_tool_call_log_context.cell

let create_turn_ctx_cell = Keeper_tool_call_log_context.create_cell
let set_turn_context = Keeper_tool_call_log_context.set_turn_context
let get_turn_context = Keeper_tool_call_log_context.get_turn_context

let runtime_observability_contract_json_for_call =
  Keeper_tool_call_log_context.runtime_observability_contract_json_for_call
;;

let action_radius_json_for_call =
  Keeper_tool_call_log_context.action_radius_json_for_call
;;

let parse_tool_output_json_sanitized =
  Keeper_tool_call_log_route_evidence.parse_tool_output_json_sanitized
;;

let route_evidence_json_of_tool_io ~tool_name ~input ~output_text =
  Keeper_tool_call_log_route_evidence.route_evidence_json_of_tool_io
    ~max_output_len
    ~tool_name
    ~input
    ~output_text
;;

let store_ref : Dated_jsonl.t option ref = ref None
let configured_store_ref : (string * string) option ref = ref None

type append_entry =
  { store : Dated_jsonl.t
  ; keeper_name : string
  ; tool_name : string
  ; trace_id : string option
  ; json : Yojson.Safe.t
  }

let append_queue_capacity = 4096
let append_flush_interval_s = 0.5
let append_queue_mu = Stdlib.Mutex.create ()
let append_queue : append_entry Stdlib.Queue.t = Stdlib.Queue.create ()
let async_append_active = Atomic.make false
let append_queue_dropped = Atomic.make 0

let with_append_queue_lock f =
  Stdlib.Mutex.lock append_queue_mu;
  Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock append_queue_mu) f

let queued_count_for_testing () =
  with_append_queue_lock (fun () -> Stdlib.Queue.length append_queue)

let dropped_count_for_testing () = Atomic.get append_queue_dropped

(* RFC-0162 §3.3: default retention. The earlier opt-in policy
   (None unless env explicitly set positive) let `.masc/tool_calls/`
   grow unbounded; RFC-0162 §1.2 observed 30 day-files / 465 MB on a
   developer workstation. The dashboard count_entries scan
   (Phase 0b) and the host kern.maxfiles budget both degrade
   monotonically with directory size.

   The mli already documents "default is 30 days, and values <= 0
   disable pruning" (lib/keeper_tool_call_log.mli:99-103), so this
   change is a contract recovery — the ml implementation was
   drifted from its own stated contract. Operators that want the
   prior unbounded behavior must now opt out explicitly with
   MASC_TOOL_CALL_LOG_RETENTION_DAYS=0. *)
let retention_days_default = 30

let retention_days () =
  match Sys.getenv_opt "MASC_TOOL_CALL_LOG_RETENTION_DAYS" with
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some days when days > 0 -> Some days
     | Some _ -> None      (* explicit 0 or negative → retain forever *)
     | None -> Some retention_days_default  (* malformed → safe default *))
  | None -> Some retention_days_default

let init ?cluster_name ~base_path () =
  let cluster_name =
    Option.value ~default:(Env_config_core.cluster_name ()) cluster_name
  in
  let masc_root = Workspace_utils.masc_root_dir_from ~base_path ~cluster_name in
  let dir = Filename.concat masc_root "tool_calls" in
  configured_store_ref := Some (masc_root, dir);
  try
    let retention_days = retention_days () in
    let store = Dated_jsonl.create ~base_dir:dir ?retention_days () in
    store_ref := Some store
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    store_ref := None;
    Log.Misc.warn "keeper_tool_call_log: init failed: %s" (Printexc.to_string exn);
    (try
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_call_io"
         ~producer:"keeper_tool_call_log.init"
         ~durable_store:dir
         ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
         ~stale_reason:"tool_call_io_init_failed"
         ~exn
         ()
     with
     | Eio.Cancel.Cancelled _ as cancel -> raise cancel
     | gap_exn ->
       Log.Misc.warn
         "keeper_tool_call_log: init coverage gap append failed: %s"
         (Printexc.to_string gap_exn))
;;

let reset_for_testing () =
  store_ref := None;
  configured_store_ref := None;
  Atomic.set async_append_active false;
  Atomic.set append_queue_dropped 0;
  with_append_queue_lock (fun () -> Stdlib.Queue.clear append_queue);
  Hashtbl.reset pending_truncation
;;

let store_dir () =
  match !store_ref with
  | Some store -> Some (Dated_jsonl.base_dir store)
  | None -> None
;;

let current_log_path () =
  match store_dir () with
  | None -> None
  | Some dir ->
    let tm = Unix.gmtime (Unix.gettimeofday ()) in
    let month =
      Printf.sprintf "%04d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    in
    let day = Printf.sprintf "%02d.jsonl" tm.Unix.tm_mday in
    Some (Filename.concat (Filename.concat dir month) day)
;;

let configured_masc_root () = Option.map fst !configured_store_ref

let record_append_coverage_gap ~store ~keeper_name ~tool_name ?trace_id exn =
  let durable_store = Dated_jsonl.base_dir store in
  let masc_root = Filename.dirname durable_store in
  try
    Telemetry_coverage_gap.record
      ~masc_root
      ~source:"tool_call_io"
      ~producer:"keeper_hooks_oas|mcp_server_eio_call_tool"
      ~durable_store
      ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
      ~stale_reason:"tool_call_io_append_failed"
      ~keeper_name
      ?trace_id
      ~error:(Printf.sprintf "%s/%s: %s" keeper_name tool_name (Printexc.to_string exn))
      ~exn
      ()
  with
  | Eio.Cancel.Cancelled _ as cancel -> raise cancel
  | gap_exn ->
    Log.Misc.warn
      "keeper_tool_call_log: coverage gap append failed for %s/%s: %s"
      keeper_name
      tool_name
      (Printexc.to_string gap_exn)
;;

let record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id () =
  match !configured_store_ref with
  | None -> ()
  | Some (masc_root, durable_store) ->
    (try
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"tool_call_io"
         ~producer:"keeper_hooks_oas|mcp_server_eio_call_tool"
         ~durable_store
         ~dashboard_surface:"/api/v1/keepers/:name/tool-calls"
         ~stale_reason:"tool_call_io_store_unavailable"
         ~keeper_name
         ?trace_id
         ~error:
           (Printf.sprintf "%s/%s: tool call store unavailable" keeper_name tool_name)
         ()
     with
     | Eio.Cancel.Cancelled _ as cancel -> raise cancel
     | gap_exn ->
       Log.Misc.warn
         "keeper_tool_call_log: unavailable coverage gap append failed for %s/%s: %s"
         keeper_name
         tool_name
         (Printexc.to_string gap_exn))
;;

let append_to_store (entry : append_entry) =
  match Dated_jsonl.append_result entry.store entry.json with
  | Ok () -> ()
  | Error msg ->
    let exn = Sys_error msg in
    let trace_id = entry.trace_id in
    Keeper_fd_pressure.note_exception ~site:"keeper_tool_call_log.append" exn;
    Keeper_disk_pressure.note_exception ~site:"keeper_tool_call_log.append" exn;
    Log.Misc.warn
      "keeper_tool_call_log: append failed for %s/%s: %s"
      entry.keeper_name
      entry.tool_name
      msg;
    record_append_coverage_gap
      ~store:entry.store
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?trace_id
      exn
;;

let take_queued_append () =
  with_append_queue_lock (fun () ->
    if Stdlib.Queue.is_empty append_queue
    then None
    else Some (Stdlib.Queue.take append_queue))
;;

let drain_queued_appends () =
  let count = ref 0 in
  let rec loop () =
    match take_queued_append () with
    | None -> !count
    | Some entry ->
      append_to_store entry;
      incr count;
      loop ()
  in
  loop ()
;;

let flush_now () = ignore (drain_queued_appends () : int)

let enqueue_append (entry : append_entry) =
  let dropped =
    with_append_queue_lock (fun () ->
      if Stdlib.Queue.length append_queue >= append_queue_capacity
      then true
      else (
        Stdlib.Queue.add entry append_queue;
        false))
  in
  if dropped
  then (
    Otel_metric_store.inc_counter Otel_metric_store.metric_keeper_tool_call_log_queue_dropped ();
    let dropped_count = Atomic.fetch_and_add append_queue_dropped 1 + 1 in
    if dropped_count = 1 || dropped_count mod 1024 = 0
    then
      Log.Misc.warn
        "keeper_tool_call_log: dropped %d record(s) because async append queue is full"
        dropped_count)
;;

let append_or_enqueue entry =
  if Atomic.get async_append_active then enqueue_append entry else append_to_store entry
;;

let start_flush_fiber ~sw ~clock =
  Atomic.set async_append_active true;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Log.Misc.info
      "keeper_tool_call_log: async flush fiber started (interval=%.1fs, capacity=%d)"
      append_flush_interval_s
      append_queue_capacity;
    let rec loop () =
      match Eio.Time.sleep clock append_flush_interval_s with
      | exception Eio.Cancel.Cancelled _ -> `Stop_daemon
      | () ->
        (match drain_queued_appends () with
         | _ -> ()
         | exception Eio.Cancel.Cancelled _ -> ()
         | exception exn ->
           Log.Misc.warn
             "keeper_tool_call_log: async flush iteration failed: %s"
             (Printexc.to_string exn));
        loop ()
    in
    loop ());
  Shutdown.register ~name:"keeper_tool_call_log_flush" ~priority:24 (fun () ->
    try
      let n = drain_queued_appends () in
      if n > 0
      then Log.Misc.info "keeper_tool_call_log: shutdown flush wrote %d records" n
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Misc.warn
        "keeper_tool_call_log: shutdown flush failed: %s"
        (Printexc.to_string exn))
;;

(** [blob_aware_output_json safe_output] wraps a tool-output string for
    persistence as the [output] field. When [safe_output] is the OCaml
    [%S]-quoted [masc:blob ...] marker produced by
    [Tool_output.encode_for_oas], the wire format escapes the inner
    preview JSON twice (OCaml string-literal + JSON string), which makes
    the telemetry record illegible and inflates disk usage by 30-40%.

    We decode the marker and emit a structured object instead:
      {"_blob": {"sha256":"...", "bytes":N, "mime":"...", "preview":"..."}}

    Non-marker outputs keep the historical [String _] shape so that
    older readers (dashboard, jq scripts) keep working. The dashboard
    consumers are updated in the same change to accept either shape. *)
let blob_aware_output_json (output : string) : Yojson.Safe.t =
  match Tool_output.decode_from_oas output with
  | Tool_output.Stored { sha256; bytes; preview; mime } ->
    `Assoc
      [ ( "_blob"
        , `Assoc
            [ "sha256", `String sha256
            ; "bytes", `Int bytes
            ; "mime", `String mime
            ; "preview", `String preview
            ] )
      ]
  | Tool_output.Inline _ -> `String output
;;

let semantic_outcome_of_output ~success output =
  let semantic_status_outcome = function
    | "ok" -> Some (true, "success")
    | "no_match" -> Some (true, "no_match")
    | "partial" -> Some (false, "partial")
    | "blocked" -> Some (false, "blocked")
    | "timeout" -> Some (false, "timeout")
    | "runtime_error" -> Some (false, "runtime_error")
    | _ -> None
  in
  match parse_tool_output_json_sanitized output with
  | Ok json ->
    let ok_field = Safe_ops.json_bool_opt "ok" json in
    let error_field = Safe_ops.json_string_opt "error" json |> Option.map String.trim in
    let semantic_status =
      Safe_ops.json_string_opt "semantic_status" json
      |> Option.map String.trim
    in
    (match error_field with
     | Some "tool_not_allowed" -> false, "policy_denied"
     | _ ->
       (match Option.bind semantic_status semantic_status_outcome with
        | Some outcome -> outcome
        | None ->
          (match error_field with
           | Some error when error <> "" -> false, "structured_error"
           | _ ->
             (match ok_field with
              | Some false -> false, "structured_error"
              | Some true -> true, "success"
              | None -> if success then true, "success" else false, "tool_failure"))))
  | Error _ -> if success then true, "success" else false, "tool_failure"
;;

let input_to_json (input : Yojson.Safe.t) : Yojson.Safe.t =
  (* Per-leaf marker-aware truncation. Previously
     [String.sub (Yojson.Safe.to_string input) 0 (max - suffix)] chopped
     through a [masc:blob ...] marker embedded in a nested JSON string
     value and stranded sha256/bytes/mime halfway, breaking the keeper
     artifact hydrator on replay. *)
  let input = Observability_redact.preview_json_strings ~max_len:max_output_len input in
  let s = Yojson.Safe.to_string input in
  if String.length s > max_output_len
  then `String (Observability_redact.redact_preview ~max_len:max_output_len s)
  else input
;;

let log_call
      ~keeper_name
      ~tool_name
      ~(input : Yojson.Safe.t)
      ~(output_text : string)
      ~(success : bool)
      ~(duration_ms : float)
      ?(model : string = "")
      ?agent_name
      ?lane
      ?tool_choice
      ?thinking_enabled
      ?thinking_budget
      ?prompt_fingerprint
      ?execution_id
      ?tool_use_id
      ?trace_id
      ?session_id
      ?generation
      ?turn
      ?keeper_turn_id
      ?task_id
      ?goal_ids
      ?sandbox_profile
      ?sandbox_root
      ?allowed_paths
      ?network_mode
      ?approval_mode
      ?runtime_profile
      ?result_bytes
      ?truncated_to
      ()
  =
  if Observability_redact.is_denied_tool ~tool_name
  then ()
  else (
    match !store_ref with
    | None -> record_unavailable_coverage_gap ~keeper_name ~tool_name ?trace_id ()
    | Some store ->
      (* RFC-0225 §3.3: no ambient turn-context fallback. Both production
         callers (keeper_hooks_oas, mcp_server_eio_call_tool) pass their
         run identity explicitly; filling [None] from a keeper-name-keyed
         global could attach an unrelated concurrent run's identity. A
         [None] field now persists as absent, which is honest. *)
      let model_field =
        if model = ""
        then []
        else [ "model", `String (Boundary_redaction.to_string Boundary_redaction.runtime_model_label) ]
      in
      let runtime_profile_field =
        match runtime_profile with
        | Some value when String.trim value <> "" -> [ "runtime_profile", `String value ]
        | _ -> []
      in
      let result_bytes_field =
        match result_bytes with
        | Some n -> [ "result_bytes", `Int n ]
        | None -> []
      in
      let truncated_to_field =
        match truncated_to with
        | Some n -> [ "truncated_to", `Int n ]
        | None -> []
      in
      let lane_field =
        match lane with
        | Some value -> [ "lane", `String value ]
        | None -> []
      in
      let tool_choice_field =
        match tool_choice with
        | Some value -> [ "tool_choice", `String value ]
        | None -> []
      in
      let thinking_enabled_field =
        match thinking_enabled with
        | Some value -> [ "thinking_enabled", `Bool value ]
        | None -> []
      in
      let thinking_budget_field =
        match thinking_budget with
        | Some value -> [ "thinking_budget", `Int value ]
        | None -> []
      in
      let prompt_fingerprint_field =
        match prompt_fingerprint with
        | Some value -> [ "prompt_fingerprint", `String value ]
        | None -> []
      in
      let trace_id_field =
        match trace_id with
        | Some value -> [ "trace_id", `String value ]
        | None -> []
      in
      (* RFC-0233 PR-1: canonical per-execution join key, minted once at
         the dispatch boundary and shared with the trajectory row. *)
      let execution_id_field =
        match execution_id with
        | Some value ->
          [ "execution_id", `String (Ids.Execution_id.to_string value) ]
        | None -> []
      in
      (* RFC-0233 PR-2: provider call id — the key the oas-event rows
         carry, joining this store to oas:tool_called/oas:tool_completed. *)
      let tool_use_id_field =
        match tool_use_id with
        | Some value when value <> "" -> [ "tool_use_id", `String value ]
        | Some _ | None -> []
      in
      let session_id_field =
        match session_id with
        | Some value -> [ "session_id", `String value ]
        | None -> []
      in
      let generation_field =
        match generation with
        | Some value -> [ "generation", `Int value ]
        | None -> []
      in
      let turn_field =
        match turn with
        | Some value -> [ "turn", `Int value ]
        | None -> []
      in
      let keeper_turn_id_field =
        match keeper_turn_id with
        | Some value -> [ "keeper_turn_id", `Int value ]
        | None -> []
      in
      let task_id_field =
        match task_id with
        | Some value -> [ "task_id", `String value ]
        | None -> []
      in
      let goal_ids_field =
        match goal_ids with
        | Some values ->
          [ "goal_ids", `List (List.map (fun value -> `String value) values) ]
        | None -> []
      in
      let sandbox_profile_field =
        match sandbox_profile with
        | Some value -> [ "sandbox_profile", `String value ]
        | None -> []
      in
      let network_mode_field =
        match network_mode with
        | Some value -> [ "network_mode", `String value ]
        | None -> []
      in
      let approval_mode_field =
        match approval_mode with
        | Some value -> [ "approval_mode", `String value ]
        | None -> []
      in
      let safe_input = input_to_json (Observability_redact.redact_json_value input) in
      let safe_output =
        Observability_redact.redact_preview ~max_len:max_output_len output_text
      in
      let output_json = blob_aware_output_json safe_output in
      let semantic_success, semantic_outcome =
        semantic_outcome_of_output ~success safe_output
      in
      let runtime_contract =
        Keeper_runtime_contract.runtime_observability_contract_json_from_fields
          ~keeper_name
          ?agent_name
          ?trace_id
          ?session_id
          ?generation
          ?keeper_turn_id
          ?task_id
          ?goal_ids
          ?sandbox_profile
          ?sandbox_root
          ?allowed_paths
          ?network_mode
          ?approval_mode
          ?runtime_profile
          ()
      in
      let error = if success then None else Some safe_output in
      let action_radius =
        Keeper_runtime_contract.action_radius_json
          ~tool_name
          ~input:safe_input
          ~success
          ~duration_ms
          ?error
          ?sandbox_target:sandbox_profile
          ()
      in
      let route_evidence_field =
        match
          route_evidence_json_of_tool_io ~tool_name ~input:safe_input ~output_text
        with
        | Some evidence -> [ "route_evidence", evidence ]
        | None -> []
      in
      let json =
        `Assoc
          ([ "ts", `Float (Time_compat.now ())
           ; "keeper", `String keeper_name
           ; "tool", `String tool_name
           ; "input", safe_input
           ; "output", output_json
           ; "success", `Bool success
           ; "semantic_success", `Bool semantic_success
           ; "semantic_outcome", `String semantic_outcome
           ; "duration_ms", `Float duration_ms
           ; "runtime_contract", runtime_contract
           ; "action_radius", action_radius
           ]
           @ route_evidence_field
           @ model_field
           @ runtime_profile_field
           @ lane_field
           @ tool_choice_field
           @ thinking_enabled_field
           @ thinking_budget_field
           @ prompt_fingerprint_field
           @ execution_id_field
           @ tool_use_id_field
           @ trace_id_field
           @ session_id_field
           @ generation_field
           @ turn_field
           @ keeper_turn_id_field
           @ task_id_field
           @ goal_ids_field
           @ sandbox_profile_field
           @ network_mode_field
           @ approval_mode_field
           @ result_bytes_field
           @ truncated_to_field)
      in
      (* Sanitize UTF-8 before persisting.  Tool output may contain invalid
         byte sequences (truncated UTF-8, binary output from subprocess
         captures) that would corrupt the JSONL file and cause downstream
         readers — including the dashboard — to silently skip entire rows. *)
      let safe_json = Inference_utils.sanitize_json_utf8 json in
      append_or_enqueue { store; keeper_name; tool_name; trace_id; json = safe_json })
;;

let read_recent ?keeper_name ?(n = 100) () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    match !store_ref with
    | None -> []
    | Some store ->
      let keeper_matches name json =
        match Safe_ops.json_string_opt "keeper" json with
        | Some k -> String.equal k name
        | None -> false
      in
      (* Single-pass: read from store, filter, and collect last n in one traversal *)
      let raw = Dated_jsonl.read_recent store (n * 5) in
      let buf = Array.make n (`Null : Yojson.Safe.t) in
      let pos = ref 0 in
      let total = ref 0 in
      List.iter
        (fun json ->
           let dominated =
             match keeper_name with
             | None -> true
             | Some name -> keeper_matches name json
           in
           if dominated
           then (
             buf.(!pos mod n) <- json;
             incr pos;
             incr total))
        raw;
      let count = min !total n in
      if count = 0
      then []
      else (
        let start = if !total <= n then 0 else !pos mod n in
        List.init count (fun i -> buf.((start + i) mod n))))
;;

let iso_date_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf
    "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
;;

let ts_of_entry (json : Yojson.Safe.t) : float option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (Float.of_int i)
     | _ -> None)
  | _ -> None
;;

let read_window ?keeper_name ~(window_hours : float) () : Yojson.Safe.t list =
  if window_hours <= 0.0
  then []
  else (
    match !store_ref with
    | None -> []
    | Some store ->
      let now = Time_compat.now () in
      let since_ts = now -. (window_hours *. Masc_time_constants.hour) in
      let since_date = iso_date_of_unix since_ts in
      let until_date = iso_date_of_unix now in
      let keeper_matches name json =
        match Safe_ops.json_string_opt "keeper" json with
        | Some k -> String.equal k name
        | None -> false
      in
      Dated_jsonl.read_range store ~since:since_date ~until:until_date
      |> List.filter (fun json ->
        let in_window =
          match ts_of_entry json with
          | Some ts -> ts >= since_ts
          | None -> false
        in
        in_window
        &&
        match keeper_name with
        | None -> true
        | Some name -> keeper_matches name json))
;;

let read_latest ?keeper_name () : Yojson.Safe.t option =
  let keeper_matches name json =
    match Safe_ops.json_string_opt "keeper" json with
    | Some k -> String.equal k name
    | None -> false
  in
  match !store_ref with
  | None -> None
  | Some store ->
    let scan_limit =
      match keeper_name with
      | None -> 1
      | Some _ -> 16
    in
    let raw_lines = Dated_jsonl.read_recent_lines store scan_limit in
    let rec loop = function
      | [] -> None
      | line :: rest ->
        (match Yojson.Safe.from_string line with
         | exception Yojson.Json_error _ -> loop rest
         | json ->
           let dominated =
             match keeper_name with
             | None -> true
             | Some name -> keeper_matches name json
           in
           if dominated then Some json else loop rest)
    in
    loop (List.rev raw_lines)
;;
