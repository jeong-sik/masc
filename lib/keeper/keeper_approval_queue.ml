(** Durable, nonblocking HITL requests for Keeper external effects. *)

include Keeper_approval_queue_rules

type storage_error =
  { path : string
  ; reason : string
  }

type approved_resolution_request =
  { keeper_name : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type grant_error =
  | Grant_store_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type grant_consumption =
  | Consumption_committed
  | Consumption_already_committed
  | Consumption_not_matching

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  }

type install_error = Install_storage_failed of storage_error

type persisted_delivery =
  { entry : pending_approval
  ; decision : decision
  ; source : decision_source
  ; remember_rule : bool
  ; created_by : string option
  ; grant_consumed : bool
  }

let storage_error_to_string error =
  Printf.sprintf "%s: %s" error.path error.reason
;;

let grant_error_to_string = function
  | Grant_store_unavailable error -> storage_error_to_string error
  | Grant_workspace_mismatch
      { approval_id; requested_base_path; stored_base_path } ->
    Printf.sprintf
      "approval %s belongs to workspace %s, not %s"
      approval_id
      stored_base_path
      requested_base_path
  | Grant_still_pending approval_id ->
    Printf.sprintf "approval %s has not been resolved" approval_id
  | Grant_resolution_not_approved approval_id ->
    Printf.sprintf "approval %s was not approved" approval_id
  | Grant_resolution_missing approval_id ->
    Printf.sprintf "approval %s has no durable resolution journal" approval_id
;;

let install_error_to_string = function
  | Install_storage_failed error -> storage_error_to_string error
;;

let pending_store_version = 2
let pending_store_surface = "keeper_gate_pending"
let pending_store_mu = Stdlib.Mutex.create ()
let deliveries : persisted_delivery SMap.t Atomic.t = Atomic.make SMap.empty
let unavailable_stores : storage_error SMap.t Atomic.t = Atomic.make SMap.empty

let mark_store_unavailable_unlocked ~base_path error =
  Atomic.set
    unavailable_stores
    (SMap.add base_path error (Atomic.get unavailable_stores))
;;

let clear_store_unavailable_unlocked ~base_path =
  Atomic.set
    unavailable_stores
    (SMap.remove base_path (Atomic.get unavailable_stores))
;;

let pending_store_path ~base_path =
  Keeper_gate_path.pending ~base_path
;;

let report_pending_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", pending_store_surface; "reason", reason ]
        ())
    ~surface:pending_store_surface
    ~reason
    ~path
    ~detail
;;

let pending_entry_to_yojson (entry : pending_approval) =
  `Assoc
    [ "id", `String entry.id
    ; "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "input_hash", `String entry.input_hash
    ; "input", entry.input
    ; "requested_at", `Float entry.requested_at
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; ( "request_context"
      , match entry.request_context with
        | Some context -> context
        | None -> `Null )
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "goal_ids", Json_util.json_string_list entry.goal_ids
    ; "continuation_channel", Keeper_continuation_channel.to_yojson entry.continuation_channel
    ; "summary_status", summary_status_to_yojson entry.summary_status
    ]
;;

let approval_decision_to_yojson = function
  | Agent_sdk.Hooks.Approve -> `Assoc [ "kind", `String "approve" ]
  | Agent_sdk.Hooks.Reject reason ->
    `Assoc [ "kind", `String "reject"; "reason", `String reason ]
  | Agent_sdk.Hooks.Edit input ->
    `Assoc [ "kind", `String "edit"; "input", input ]
;;

let persisted_delivery_to_yojson delivery =
  `Assoc
    [ "entry", pending_entry_to_yojson delivery.entry
    ; "decision", approval_decision_to_yojson delivery.decision
    ; "source", `String (decision_source_to_string delivery.source)
    ; "remember_rule", `Bool delivery.remember_rule
    ; "created_by", Json_util.string_opt_to_json delivery.created_by
    ; "grant_consumed", `Bool delivery.grant_consumed
    ]
;;

let map_values_for_base ~base_path map project =
  SMap.bindings map
  |> List.filter_map (fun (_id, value) ->
    if String.equal (project value).audit_base_path base_path then Some value else None)
;;

let snapshot_to_yojson ~base_path ~pending_map ~delivery_map =
  let pending_entries =
    map_values_for_base ~base_path pending_map Fun.id
    |> List.map pending_entry_to_yojson
  in
  let delivery_entries =
    map_values_for_base ~base_path delivery_map (fun delivery -> delivery.entry)
    |> List.map persisted_delivery_to_yojson
  in
  `Assoc
    [ "version", `Int pending_store_version
    ; "pending", `List pending_entries
    ; "deliveries", `List delivery_entries
    ]
;;

let persist_snapshot_unlocked ~base_path ~pending_map ~delivery_map =
  let path = pending_store_path ~base_path in
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error error
  | None ->
    (try
       Fs_compat.mkdir_p (Filename.dirname path);
       let body =
         snapshot_to_yojson ~base_path ~pending_map ~delivery_map
         |> Yojson.Safe.pretty_to_string
       in
       (match Fs_compat.save_file_atomic path body with
        | Ok () -> Ok ()
        | Error reason -> Error { path; reason })
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error { path; reason = Printexc.to_string exn })
;;

let reject_unknown_fields ~surface ~allowed fields =
  let rec duplicate seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else duplicate (key :: seen) rest
  in
  match duplicate [] fields with
  | Some field -> Error (Printf.sprintf "%s contains duplicate field %s" surface field)
  | None ->
    (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
     | None -> Ok ()
     | Some (field, _) ->
       Error (Printf.sprintf "%s contains unsupported field %s" surface field))
;;

let required_string ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_member ~surface field fields =
  match List.assoc_opt field fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let optional_string ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) -> Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string or null" surface field)
;;

let optional_nonnegative_int ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) when value >= 0 -> Ok (Some value)
  | Some _ ->
    Error (Printf.sprintf "%s.%s must be a non-negative integer or null" surface field)
;;

let required_float ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (Float.of_int value)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a number" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_string_list ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`List values) ->
    let rec parse index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> parse (index + 1) (value :: acc) rest
      | _ :: _ ->
        Error (Printf.sprintf "%s.%s[%d] must be a string" surface field index)
    in
    parse 0 [] values
  | Some _ -> Error (Printf.sprintf "%s.%s must be an array" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let pending_entry_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.entry" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "id"
          ; "keeper_name"
          ; "tool_name"
          ; "input_hash"
          ; "input"
          ; "requested_at"
          ; "turn_id"
          ; "request_context"
          ; "task_id"
          ; "goal_id"
          ; "goal_ids"
          ; "continuation_channel"
          ; "summary_status"
          ]
        fields
    in
    let* id = required_string ~surface "id" fields in
    let* keeper_name = required_string ~surface "keeper_name" fields in
    let* tool_name = required_string ~surface "tool_name" fields in
    let* input_hash = required_string ~surface "input_hash" fields in
    let* input = required_member ~surface "input" fields in
    let expected_hash = request_fingerprint input in
    let* () =
      if String.equal input_hash expected_hash
      then Ok ()
      else Error (Printf.sprintf "%s.input_hash does not match input" surface)
    in
    let* requested_at = required_float ~surface "requested_at" fields in
    let* turn_id = optional_nonnegative_int ~surface "turn_id" fields in
    let request_context =
      match List.assoc_opt "request_context" fields with
      | None | Some `Null -> None
      | Some context -> Some context
    in
    let* task_id = optional_string ~surface "task_id" fields in
    let* goal_id = optional_string ~surface "goal_id" fields in
    let* goal_ids = required_string_list ~surface "goal_ids" fields in
    let* continuation_json = required_member ~surface "continuation_channel" fields in
    let* continuation_channel = Keeper_continuation_channel.of_yojson continuation_json in
    let* summary_json = required_member ~surface "summary_status" fields in
    let* summary_status = summary_status_of_yojson_with_error summary_json in
    Ok
      { id
      ; keeper_name
      ; tool_name
      ; input_hash
      ; input
      ; requested_at
      ; turn_id
      ; request_context
      ; task_id
      ; goal_id
      ; goal_ids
      ; continuation_channel
      ; audit_base_path = base_path
      ; summary_status
      }
  | _ -> Error "gate_pending.entry must be a JSON object"
;;

let approval_decision_of_yojson json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* kind = required_string ~surface:"gate_pending.decision" "kind" fields in
    (match kind with
     | "approve" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind" ]
           fields
       in
       Ok Agent_sdk.Hooks.Approve
     | "reject" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind"; "reason" ]
           fields
       in
       let* reason = required_string ~surface:"gate_pending.decision" "reason" fields in
       Ok (Agent_sdk.Hooks.Reject reason)
     | "edit" ->
       let* () =
         reject_unknown_fields
           ~surface:"gate_pending.decision"
           ~allowed:[ "kind"; "input" ]
           fields
       in
       let* input = required_member ~surface:"gate_pending.decision" "input" fields in
       Ok (Agent_sdk.Hooks.Edit input)
     | other -> Error (Printf.sprintf "gate_pending.decision kind %S is unknown" other))
  | _ -> Error "gate_pending.decision must be a JSON object"
;;

let persisted_delivery_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending.delivery" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "entry"
          ; "decision"
          ; "source"
          ; "remember_rule"
          ; "created_by"
          ; "grant_consumed"
          ]
        fields
    in
    let* entry_json = required_member ~surface "entry" fields in
    let* entry = pending_entry_of_yojson ~base_path entry_json in
    let* decision_json = required_member ~surface "decision" fields in
    let* decision = approval_decision_of_yojson decision_json in
    let* source_raw = required_string ~surface "source" fields in
    let* source =
      match decision_source_of_string source_raw with
      | Some source -> Ok source
      | None -> Error (Printf.sprintf "%s.source %S is unknown" surface source_raw)
    in
    let* remember_rule =
      match List.assoc_opt "remember_rule" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".remember_rule must be a boolean")
      | None -> Error (surface ^ ".remember_rule is required")
    in
    let* created_by = optional_string ~surface "created_by" fields in
    let* grant_consumed =
      match List.assoc_opt "grant_consumed" fields with
      | Some (`Bool value) -> Ok value
      | Some _ -> Error (surface ^ ".grant_consumed must be a boolean")
      | None -> Error (surface ^ ".grant_consumed is required")
    in
    let* () =
      match decision, grant_consumed with
      | Agent_sdk.Hooks.Approve, _ -> Ok ()
      | (Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _), false -> Ok ()
      | (Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _), true ->
        Error (surface ^ ".grant_consumed is valid only for approve")
    in
    Ok { entry; decision; source; remember_rule; created_by; grant_consumed }
  | _ -> Error "gate_pending.delivery must be a JSON object"
;;

let map_of_unique_entries ~surface ~id_of entries =
  let rec build map = function
    | [] -> Ok map
    | entry :: rest ->
      let id = id_of entry in
      if SMap.mem id map
      then Error (Printf.sprintf "%s contains duplicate id %s" surface id)
      else build (SMap.add id entry map) rest
  in
  build SMap.empty entries
;;

let first_shared_id left right =
  SMap.fold
    (fun id _ found ->
       match found with
       | Some _ -> found
       | None -> if SMap.mem id right then Some id else None)
    left
    None
;;

let parse_list ~surface parse = function
  | `List values ->
    let rec loop index acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match parse value with
         | Ok parsed -> loop (index + 1) (parsed :: acc) rest
         | Error reason -> Error (Printf.sprintf "%s[%d]: %s" surface index reason))
    in
    loop 0 [] values
  | _ -> Error (surface ^ " must be an array")
;;

let snapshot_of_yojson ~base_path json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "gate_pending" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:[ "version"; "pending"; "deliveries" ]
        fields
    in
    let* () =
      match List.assoc_opt "version" fields with
      | Some (`Int version) when version = pending_store_version -> Ok ()
      | Some (`Int version) ->
        Error (Printf.sprintf "%s.version %d is unsupported" surface version)
      | Some _ -> Error (surface ^ ".version must be an integer")
      | None -> Error (surface ^ ".version is required")
    in
    let* pending_json = required_member ~surface "pending" fields in
    let* pending_entries =
      parse_list ~surface:"gate_pending.pending" (pending_entry_of_yojson ~base_path) pending_json
    in
    let* delivery_json = required_member ~surface "deliveries" fields in
    let* delivery_entries =
      parse_list
        ~surface:"gate_pending.deliveries"
        (persisted_delivery_of_yojson ~base_path)
        delivery_json
    in
    let* pending_map =
      map_of_unique_entries
        ~surface:"gate_pending.pending"
        ~id_of:(fun (entry : pending_approval) -> entry.id)
        pending_entries
    in
    let* delivery_map =
      map_of_unique_entries
        ~surface:"gate_pending.deliveries"
        ~id_of:(fun (delivery : persisted_delivery) -> delivery.entry.id)
        delivery_entries
    in
    let* () =
      match first_shared_id pending_map delivery_map with
      | None -> Ok ()
      | Some id -> Error (Printf.sprintf "gate_pending id %s exists in both states" id)
    in
    Ok (pending_map, delivery_map)
  | _ -> Error "gate_pending snapshot must be a JSON object"
;;

let load_snapshot_unlocked ~base_path =
  let path = pending_store_path ~base_path in
  try
    if not (Sys.file_exists path)
    then Ok (SMap.empty, SMap.empty)
    else (
      match Safe_ops.read_json_file_safe path with
      | Error reason ->
        report_pending_read_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~path
          ~detail:reason;
        Error { path; reason }
      | Ok json ->
        (match snapshot_of_yojson ~base_path json with
         | Ok snapshot -> Ok snapshot
         | Error reason ->
           report_pending_read_drop
             ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
             ~path
             ~detail:reason;
           Error { path; reason }))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    report_pending_read_drop
      ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
      ~path
      ~detail:reason;
    Error { path; reason }
;;

let remove_base_entries ~base_path map project =
  SMap.filter
    (fun _id value ->
       not (String.equal (project value).audit_base_path base_path))
    map
;;

let merge_loaded_map ~surface ~existing ~loaded =
  SMap.fold
    (fun id value result ->
       match result with
       | Error _ as error -> error
       | Ok map ->
         if SMap.mem id map
         then Error (Printf.sprintf "%s id %s collides with another workspace" surface id)
         else Ok (SMap.add id value map))
    loaded
    (Ok existing)
;;

(* ── Persistent audit log ────────────────────────────────── *)

(* Stdlib.Mutex: the store registry critical section only mutates an in-memory
   hashtable and creates a Dated_jsonl handle. It is also used by synchronous
   tests outside an Eio context, so an Eio mutex would either raise Get_context
   or poison the registry after a recoverable store-creation failure. *)
(** Dated JSONL audit trail for approval events.
    Stored at [<base_path>/.masc/audit-approvals/YYYY-MM/DD.jsonl].
    Dashboard and workspace-scoped keeper runs pass [base_path] explicitly so approval
    history stays with the workspace that made the decision. *)
let audit_stores_mu = Stdlib.Mutex.create ()

let audit_io_mu = Stdlib.Mutex.create ()
let audit_stores : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4

(* Runtime trust asks for per-keeper latest audit state across the same global
   audit tail. Cache the raw tail briefly so a keeper snapshot does one shared
   JSONL read instead of N identical scans. *)
type recent_audit_cache_entry =
  { rows : Yojson.Safe.t list
  ; observed_at : float
  }
;;

let recent_audit_cache_mu = Stdlib.Mutex.create ()
let recent_audit_cache : (string, recent_audit_cache_entry) Hashtbl.t =
  Hashtbl.create 4
;;

let recent_audit_cache_ttl_sec = 1.0
let recent_resolved_history_limit = 20
let audit_wide_scan_min_rows = 500
let audit_wide_scan_multiplier = 64

let wide_audit_scan_window n =
  max audit_wide_scan_min_rows (max n 1 * audit_wide_scan_multiplier)
;;

let recent_audit_cache_key store limit =
  Printf.sprintf "%s:%d" (Dated_jsonl.base_dir store) limit
;;

let invalidate_recent_audit_cache_for_store store =
  let prefix = Dated_jsonl.base_dir store ^ ":" in
  Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
    Hashtbl.filter_map_inplace
      (fun key entry -> if String.starts_with ~prefix key then None else Some entry)
      recent_audit_cache)
;;

let read_recent_audit_raw store limit =
  let key = recent_audit_cache_key store limit in
  let now = Unix.gettimeofday () in
  let cached =
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      match Hashtbl.find_opt recent_audit_cache key with
      | Some entry when now -. entry.observed_at <= recent_audit_cache_ttl_sec ->
        Some entry.rows
      | _ -> None)
  in
  match cached with
  | Some rows -> rows
  | None ->
    let rows = Dated_jsonl.read_recent store limit in
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.replace recent_audit_cache key { rows; observed_at = now });
    rows
;;

let approval_audit_pending_event = "pending"
let approval_audit_resolved_event = "resolved"
let approval_audit_summary_event = "summary_updated"
let approval_sse_pending_event = "approval:pending"
let approval_sse_resolved_event = "approval:resolved"
let approval_sse_summary_event = "approval:summary_updated"

let non_empty_reason reason =
  let reason = String.trim reason in
  if String.equal reason "" then None else Some reason
;;

let approval_decision_kind_and_reason = function
  | Agent_sdk.Hooks.Approve -> "approve", None
  | Agent_sdk.Hooks.Reject reason -> "reject", non_empty_reason reason
  | Agent_sdk.Hooks.Edit _ -> "edit", None
;;

let keeper_audit_metric_label = function
  | Some keeper when String.trim keeper <> "" -> keeper
  | Some _ | None -> "aggregate"
;;

let audit_today_path base_dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  let dir = Filename.concat base_dir month in
  Fs_compat.mkdir_p dir;
  Filename.concat dir day
;;

let get_audit_store ~base_path () =
  let report_failure exn =
    Keeper_fd_pressure.note_exception ~site:"approval_audit.store_create" exn;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", "aggregate"
        ; "site", Keeper_approval_queue_failure_site.(to_label Audit_store_create)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: audit store creation failed: %s"
      (Printexc.to_string exn);
    None
  in
  try
    match
      Stdlib.Mutex.protect audit_stores_mu (fun () ->
        try
          Ok
            (match Hashtbl.find_opt audit_stores base_path with
             | Some store -> Some store
             | None ->
               let dir =
                 Filename.concat
                   (Common.masc_dir_from_base_path ~base_path)
                   "audit-approvals"
               in
               let store = Dated_jsonl.create ~base_dir:dir () in
               Hashtbl.replace audit_stores base_path store;
               Some store)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error exn)
    with
    | Ok store -> store
    | Error exn -> report_failure exn
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> report_failure exn
;;

let audit_approval_event
      ~base_path
      ~event_type
      ~id
      ~keeper_name
      ~tool_name
      ?turn_id
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?rule_match
      ?source_approval_id
      ?actor
      ?decision_source
      ?decision
      ()
  =
  let decision, decision_kind, decision_reason =
    match decision with
    | None -> "", None, None
    | Some decision ->
      let kind, reason = approval_decision_kind_and_reason decision in
      approval_decision_to_string decision, Some kind, reason
  in
  match get_audit_store ~base_path () with
  | None -> ()
  | Some store ->
    let json =
      `Assoc
        ([ "ts", `Float (Unix.gettimeofday ())
         ; "event", `String event_type
         ; "id", `String id
         ; "keeper", `String keeper_name
         ; "tool", `String tool_name
         ; "decision", `String decision
         ; "turn_id", Json_util.int_opt_to_json turn_id
         ; "task_id", Json_util.string_opt_to_json task_id
         ; "goal_id", Json_util.string_opt_to_json goal_id
         ; "goal_ids", `List (List.map (fun goal -> `String goal) goal_ids)
         ; "actor", Json_util.string_opt_to_json actor
         ; ( "decision_source"
           , match decision_source with
             | Some source -> `String (decision_source_to_string source)
             | None -> `Null )
         ]
         @ (match rule_match with
            | Some matched -> [ "rule_match", rule_match_to_yojson matched ]
            | None -> [])
         @ (match source_approval_id with
            | Some approval_id -> [ "source_approval_id", `String approval_id ]
            | None -> [])
         @ (match decision_kind with
            | Some kind -> [ "decision_kind", `String kind ]
            | None -> [])
         @ (match decision_reason with
            | Some reason -> [ "decision_reason", `String reason ]
            | None -> [])
         )
    in
    Stdlib.Mutex.protect audit_io_mu (fun () ->
      try
        Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
        invalidate_recent_audit_cache_for_store store
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> record_queue_failure ~keeper_name ~site:"audit_append" ~id ~event_type exn)
;;

let audit_rule_event ~base_path ~event_type (rule : approval_rule) =
  audit_approval_event
    ~base_path
    ~event_type
    ~id:rule.id
    ~keeper_name:rule.keeper_name
    ~tool_name:rule.tool_name
    ?source_approval_id:rule.source_approval_id
    ()
;;

let audit_scan_window ?keeper_name n =
  match keeper_name with
  | None -> max n 1
  | Some _ ->
    (* Approval audit is global, but runtime trust asks for per-keeper
         "latest" records. Scan a bounded wider window before filtering so a
         busy fleet cannot hide the target keeper behind unrelated events. *)
    wide_audit_scan_window n
;;

let resolved_audit_scan_window = wide_audit_scan_window

let record_audit_read_failure ?keeper_name ?(metric_site = Keeper_approval_queue_failure_site.Audit_read_recent) ~site exn =
  Keeper_fd_pressure.note_exception ~site exn;
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper",
        keeper_audit_metric_label keeper_name;
        "site",
        Keeper_approval_queue_failure_site.to_label metric_site
      ]
    ()
;;

let read_recent_audit ~base_path ?keeper_name ?(n = 20) () : Yojson.Safe.t list =
  if n <= 0
  then []
  else (
    match get_audit_store ~base_path () with
    | None -> []
    | Some store ->
      try
        let raw = read_recent_audit_raw store (audit_scan_window ?keeper_name n) in
        let filtered =
          match keeper_name with
          | None -> raw
          | Some name ->
            raw
            |> List.filter (fun json ->
              String.equal name (Safe_ops.json_string ~default:"" "keeper" json))
        in
        filtered |> List.rev |> List.filteri (fun idx _ -> idx < n)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_audit_read_failure ?keeper_name ~site:"approval_audit.read_recent" exn;
        [])
;;

let json_member_or_null key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> value
  | None -> `Null
;;

let closed_decision_kind_of_string value =
  match String.trim value with
  | "approve" -> Some "approve"
  | "reject" -> Some "reject"
  | "edit" -> Some "edit"
  | _ -> None
;;

let resolved_approval_decision_kind json =
  Option.bind
    (Safe_ops.json_string_opt "decision_kind" json)
    closed_decision_kind_of_string
;;

let resolved_history_event json =
  match Safe_ops.json_string_opt "event" json with
  | Some event -> String.equal event approval_audit_resolved_event
  | None -> false
;;

let resolved_approval_json_of_audit_event json =
  let resolved_at = Safe_ops.json_float_opt "ts" json in
  `Assoc
    [ "id", `String (Safe_ops.json_string ~default:"" "id" json)
    ; "event", `String (Safe_ops.json_string ~default:"" "event" json)
    ; "keeper_name", `String (Safe_ops.json_string ~default:"" "keeper" json)
    ; "tool_name", `String (Safe_ops.json_string ~default:"" "tool" json)
    ; "decision", Json_util.string_opt_to_json_trimmed (Safe_ops.json_string_opt "decision" json)
    ; "decision_kind", Json_util.string_opt_to_json_trimmed (resolved_approval_decision_kind json)
    ; "decision_reason", json_member_or_null "decision_reason" json
    ; "resolved_at", Json_util.float_opt_to_json resolved_at
    ; "turn_id", json_member_or_null "turn_id" json
    ; "task_id", json_member_or_null "task_id" json
    ; "goal_id", json_member_or_null "goal_id" json
    ; "goal_ids", json_member_or_null "goal_ids" json
    ; "actor", json_member_or_null "actor" json
    ; "decision_source", json_member_or_null "decision_source" json
    ; "rule_match", json_member_or_null "rule_match" json
    ]
;;

let list_recent_resolved_json ~base_path ?(n = recent_resolved_history_limit) ()
  : Yojson.Safe.t list
  =
  if n <= 0
  then []
  else (
    match get_audit_store ~base_path () with
    | None -> []
    | Some store ->
      try
        read_recent_audit_raw store (resolved_audit_scan_window n)
        |> List.filter resolved_history_event
        |> List.rev
        |> List.filteri (fun idx _ -> idx < n)
        |> List.map resolved_approval_json_of_audit_event
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        record_audit_read_failure
          ~metric_site:Keeper_approval_queue_failure_site.Audit_list_recent_resolved
          ~site:"approval_audit.list_recent_resolved"
          exn;
        [])
;;

let generate_id () = make_generated_id "appr"

let default_continuation_channel () =
  Keeper_continuation_channel.unrouted "no originating connector"
;;

let normalized_input_hash = request_fingerprint

type approved_delivery_lookup =
  | Approved_delivery_unconsumed of persisted_delivery
  | Approved_delivery_consumed

type grant_consumption_commit =
  | Consumption_without_audit of grant_consumption
  | Consumption_with_audit of persisted_delivery

let grant_workspace_mismatch ~base_path approval_id stored_base_path =
  Grant_workspace_mismatch
    { approval_id
    ; requested_base_path = base_path
    ; stored_base_path
    }
;;

let approved_delivery_unlocked ~base_path ~id =
  match SMap.find_opt base_path (Atomic.get unavailable_stores) with
  | Some error -> Error (Grant_store_unavailable error)
  | None ->
    (match SMap.find_opt id (Atomic.get deliveries) with
     | Some delivery ->
       let stored_base_path = delivery.entry.audit_base_path in
       if not (String.equal stored_base_path base_path)
       then Error (grant_workspace_mismatch ~base_path id stored_base_path)
       else
         (match delivery.decision with
          | Agent_sdk.Hooks.Approve ->
            if delivery.grant_consumed
            then Ok Approved_delivery_consumed
            else Ok (Approved_delivery_unconsumed delivery)
          | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _ ->
            Error (Grant_resolution_not_approved id))
     | None ->
       (match SMap.find_opt id (Atomic.get pending) with
        | Some entry ->
          if String.equal entry.audit_base_path base_path
          then Error (Grant_still_pending id)
          else
            Error
              (grant_workspace_mismatch
                 ~base_path
                 id
                 entry.audit_base_path)
        | None -> Error (Grant_resolution_missing id)))
;;

let approved_resolution_request ~base_path ~id =
  Stdlib.Mutex.protect pending_store_mu (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok Approved_delivery_consumed -> Ok None
    | Ok (Approved_delivery_unconsumed delivery) ->
      Ok
        (Some
           { keeper_name = delivery.entry.keeper_name
           ; tool_name = delivery.entry.tool_name
           ; input = delivery.entry.input
           }))
;;

let approved_resolution_state ~base_path ~id =
  Stdlib.Mutex.protect pending_store_mu (fun () ->
    match approved_delivery_unlocked ~base_path ~id with
    | Error _ as error -> error
    | Ok Approved_delivery_consumed -> Ok Resolution_consumed
    | Ok (Approved_delivery_unconsumed _) -> Ok Resolution_unconsumed)
;;

let consume_approved_resolution
      ~base_path
      ~id
      ~keeper_name
      ~tool_name
      ~input
  =
  let result =
    Stdlib.Mutex.protect pending_store_mu (fun () ->
      match approved_delivery_unlocked ~base_path ~id with
      | Error error -> Error error
      | Ok Approved_delivery_consumed ->
        Ok (Consumption_without_audit Consumption_already_committed)
      | Ok (Approved_delivery_unconsumed delivery) ->
        let entry = delivery.entry in
        if
          not
            (String.equal entry.keeper_name keeper_name
             && String.equal entry.tool_name tool_name
             && String.equal entry.input_hash (normalized_input_hash input))
        then Ok (Consumption_without_audit Consumption_not_matching)
        else
          let consumed_delivery = { delivery with grant_consumed = true } in
          let updated_deliveries =
            SMap.add id consumed_delivery (Atomic.get deliveries)
          in
          (match
             persist_snapshot_unlocked
               ~base_path
               ~pending_map:(Atomic.get pending)
               ~delivery_map:updated_deliveries
           with
           | Error error -> Error (Grant_store_unavailable error)
           | Ok () ->
             Atomic.set deliveries updated_deliveries;
             Ok (Consumption_with_audit delivery)))
  in
  match result with
  | Error _ as error -> error
  | Ok (Consumption_without_audit consumption) -> Ok consumption
  | Ok (Consumption_with_audit delivery) ->
    let entry = delivery.entry in
    audit_approval_event
      ~base_path
      ~event_type:"grant_consumed"
      ~id
      ~keeper_name:entry.keeper_name
      ~tool_name:entry.tool_name
      ?turn_id:entry.turn_id
      ?task_id:entry.task_id
      ?goal_id:entry.goal_id
      ~goal_ids:entry.goal_ids
      ~source_approval_id:id
      ~decision_source:delivery.source
      ~decision:Agent_sdk.Hooks.Approve
      ();
    Ok Consumption_committed
;;

module For_testing = struct
  let reset_audit_store () =
    Stdlib.Mutex.protect audit_stores_mu (fun () -> Hashtbl.clear audit_stores);
    Stdlib.Mutex.protect recent_audit_cache_mu (fun () ->
      Hashtbl.clear recent_audit_cache)
  ;;

  let get_pending_entry ~id = SMap.find_opt id (Atomic.get pending)

  let reset_runtime_state () =
    Stdlib.Mutex.protect pending_store_mu (fun () ->
      Atomic.set pending SMap.empty;
      Atomic.set deliveries SMap.empty;
      Atomic.set unavailable_stores SMap.empty)
  ;;

  let pending_store_path = pending_store_path
  let always_allowed_store_path ~base_path = rules_path ~base_path ()
end

let input_preview_of_json (json : Yojson.Safe.t) =
  (* Per-leaf marker-aware truncation: a naive [String.sub] on the
     serialized form would chop a [masc:blob ...] marker mid-field and
     leave sha256/bytes/mime malformed so the approval-queue viewer
     cannot round-trip the preview. *)
  let json = Observability_redact.preview_json_strings ~max_len:200 json in
  let raw = Yojson.Safe.to_string json in
  Observability_redact.redact_preview ~max_len:200 raw
;;

let create_entry
      ~id
      ~keeper_name
      ~tool_name
      ~input
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ~continuation_channel
      ~audit_base_path
      ()
  =
  let input_hash = normalized_input_hash input in
  { id
  ; keeper_name
  ; tool_name
  ; input_hash
  ; input
  ; requested_at = Unix.gettimeofday ()
  ; turn_id
  ; request_context
  ; task_id
  ; goal_id
  ; goal_ids
  ; continuation_channel
  ; audit_base_path
  ; summary_status = Summary_not_requested
  }
;;

let pending_entry_json_fields
      ?(include_input = false)
      (entry : pending_approval)
  =
  [ "id", `String entry.id
  ; "keeper_name", `String entry.keeper_name
  ; "tool_name", `String entry.tool_name
  ; "requested_at", `Float entry.requested_at
  ; "waiting_s", `Float (Unix.gettimeofday () -. entry.requested_at)
  ; "turn_id", Json_util.int_opt_to_json entry.turn_id
  ; "task_id", Json_util.string_opt_to_json entry.task_id
  ; "goal_id", Json_util.string_opt_to_json entry.goal_id
  ; "goal_ids", `List (List.map (fun goal -> `String goal) entry.goal_ids)
  ]
  @ (if include_input
     then
       [ "input", entry.input
       ; "input_preview", `String (input_preview_of_json entry.input)
       ]
     else [])
    (* The [include_input] conditional stays parenthesized so the trailing
       canonical [summary_status] field is present in every wire shape. *)
  @ [ "summary_status", summary_status_to_yojson entry.summary_status ]
;;

let broadcast_pending entry =
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_pending_event
          ; ( "payload"
            , `Assoc
                (pending_entry_json_fields
                   ~include_input:true
                   entry) )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_pending"
      ~id:entry.id
      ~event_type:approval_audit_pending_event
      exn
;;

let record_pending (entry : pending_approval) =
  Log.Keeper.info
    "HITL_APPROVAL_PENDING: id=%s keeper=%s tool=%s"
    entry.id
    entry.keeper_name
    entry.tool_name;
  audit_approval_event
    ~base_path:entry.audit_base_path
    ~event_type:approval_audit_pending_event
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ();
  broadcast_pending entry
;;

let summary_audit_extras (entry : pending_approval) : (string * Yojson.Safe.t) list =
  match entry.summary_status with
  | Summary_available summary -> [ "model_run_id", `String summary.model_run_id ]
  | Summary_failed { reason; _ } -> [ "failure_reason", `String reason ]
  | Summary_not_requested | Summary_pending -> []
;;

let record_summary_updated ~now (entry : pending_approval) =
  let event_ts =
    match entry.summary_status with
    | Summary_available summary -> summary.generated_at
    | Summary_not_requested | Summary_pending | Summary_failed _ -> now
  in
  (try
     match get_audit_store ~base_path:entry.audit_base_path () with
     | None -> ()
     | Some store ->
       let json =
         `Assoc
           ([ "ts", `Float event_ts
            ; "event", `String approval_audit_summary_event
            ; "id", `String entry.id
            ; "summary_status", summary_status_to_yojson entry.summary_status
            ]
            @ summary_audit_extras entry)
       in
       Stdlib.Mutex.protect audit_io_mu (fun () ->
         Fs_compat.append_jsonl (audit_today_path (Dated_jsonl.base_dir store)) json;
         invalidate_recent_audit_cache_for_store store)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     record_queue_failure
       ~keeper_name:entry.keeper_name
       ~site:"audit_summary"
       ~id:entry.id
       ~event_type:approval_audit_summary_event
       exn);
  try
    Sse.broadcast
      (`Assoc
         [ "type", `String approval_sse_summary_event
         ; ( "payload"
           , `Assoc
               (pending_entry_json_fields
                  ~include_input:false
                  entry) )
         ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_summary"
      ~id:entry.id
      ~event_type:approval_sse_summary_event
      exn
;;

(* ── Durable summary-state transitions ───────────────────── *)

(** Read a pending entry by id. Returns [None] if already resolved. *)
let get_pending_entry ~id : pending_approval option = SMap.find_opt id (Atomic.get pending)

(** Complete an in-flight judge exactly once. A result cannot skip the
    [Summary_pending] state or overwrite a terminal summary. *)
let complete_summary ~id summary_status =
  Stdlib.Mutex.protect pending_store_mu (fun () ->
    let map = Atomic.get pending in
    match SMap.find_opt id map with
    | None -> Ok false
    | Some ({ summary_status = Summary_pending; _ } as entry) ->
      let updated = SMap.add id { entry with summary_status } map in
      (match
         persist_snapshot_unlocked
           ~base_path:entry.audit_base_path
           ~pending_map:updated
           ~delivery_map:(Atomic.get deliveries)
       with
       | Error _ as error -> error
       | Ok () ->
         Atomic.set pending updated;
         Ok true)
    | Some
        { summary_status =
            (Summary_not_requested | Summary_available _ | Summary_failed _)
        ; _
        } ->
      Ok false)
;;

let publish_summary_update ~id =
  let now = Time_compat.now () in
  match get_pending_entry ~id with
  | Some updated -> record_summary_updated ~now updated
  | None -> ()
;;

let publish_summary_transition ~id = function
  | Ok true ->
    publish_summary_update ~id;
    Ok true
  | Ok false -> Ok false
  | Error error -> Error error
;;

let mark_summary_pending ~id =
  let result =
    Stdlib.Mutex.protect pending_store_mu (fun () ->
    let map = Atomic.get pending in
    match SMap.find_opt id map with
    | None -> Ok false
    | Some ({ summary_status = Summary_not_requested; _ } as entry) ->
      let updated = SMap.add id { entry with summary_status = Summary_pending } map in
      (match
         persist_snapshot_unlocked
           ~base_path:entry.audit_base_path
           ~pending_map:updated
           ~delivery_map:(Atomic.get deliveries)
       with
       | Error _ as error -> error
       | Ok () ->
         Atomic.set pending updated;
         Ok true)
    | Some
        { summary_status =
            (Summary_pending | Summary_available _ | Summary_failed _)
        ; _
        } ->
      Ok false)
  in
  publish_summary_transition ~id result
;;

let attach_summary ~id summary =
  let updated = complete_summary ~id (Summary_available summary) in
  publish_summary_transition ~id updated
;;

let mark_summary_failed ~id ~reason ~retryable =
  let updated = complete_summary ~id (Summary_failed { reason; retryable }) in
  publish_summary_transition ~id updated
;;

let restart_retryable_summary ~id =
  let updated =
    Stdlib.Mutex.protect pending_store_mu (fun () ->
      let map = Atomic.get pending in
      match SMap.find_opt id map with
      | Some
          ({ summary_status = Summary_failed { retryable = true; _ }; _ } as entry)
        ->
        let updated = SMap.add id { entry with summary_status = Summary_pending } map in
        (match
           persist_snapshot_unlocked
             ~base_path:entry.audit_base_path
             ~pending_map:updated
             ~delivery_map:(Atomic.get deliveries)
         with
         | Error _ as error -> error
         | Ok () ->
           Atomic.set pending updated;
           Ok true)
      | None
      | Some
          { summary_status =
              ( Summary_not_requested
              | Summary_pending
              | Summary_available _
              | Summary_failed { retryable = false; _ } )
          ; _
          } ->
        Ok false)
  in
  publish_summary_transition ~id updated
;;

let record_resolution_delivery_failure ~keeper_name ~approval_id reason =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ApprovalQueueFailures)
    ~labels:
      [ "keeper", keeper_name
      ; ( "site"
        , Keeper_approval_queue_failure_site.(to_label Resolution_delivery) )
      ]
    ();
  Log.Keeper.error
    ~keeper_name
    "hitl resolution delivery failed approval=%s: %s"
    approval_id
    reason
;;

let signal_resolution_after_commit ~base_path ~keeper_name ~approval_id =
  try
    let outcome =
      Keeper_registry.wakeup_running
        ~intent:Keeper_registry.Hitl_resolution
        ~base_path
        keeper_name
    in
    let outcome_label, detail =
      match outcome with
      | Keeper_registry.Signaled -> "signaled", "running"
      | Keeper_registry.Deferred_unregistered ->
        "deferred_unregistered", "unregistered"
      | Keeper_registry.Deferred_not_running phase ->
        "deferred_not_running", Keeper_state_machine.phase_to_string phase
      | Keeper_registry.Deferred_lifecycle denial ->
        ( "deferred_lifecycle"
        , Keeper_lifecycle_admission.autonomous_denial_to_wire denial )
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalResolutionSignal)
      ~labels:[ "keeper", keeper_name; "outcome", outcome_label ]
      ();
    Log.Keeper.info
      ~keeper_name
      "hitl resolution committed approval=%s signal=%s phase=%s"
      approval_id
      outcome_label
      detail
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Resolution_signal)
        ]
      ();
    Log.Keeper.error
      ~keeper_name
      "hitl resolution signal failed after durable commit approval=%s: %s"
      approval_id
      (Printexc.to_string exn)
;;

let commit_keeper_approval_resolution
    ~base_path ~keeper_name ~approval_id ~decision
    ~(channel : Keeper_continuation_channel.t) =
  match
    try
      Keeper_registry_event_queue.enqueue_hitl_resolution_durable_result
        ~base_path
        ~keeper_name
        ~approval_id
        ~decision
        ~channel
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Ok () -> Ok ()
  | Error reason ->
    record_resolution_delivery_failure ~keeper_name ~approval_id reason;
    Error reason
;;

let hitl_resolution_decision_of_approval_decision = function
  | Agent_sdk.Hooks.Approve -> Keeper_event_queue.Hitl_approved
  | Agent_sdk.Hooks.Reject rationale -> Keeper_event_queue.Hitl_rejected rationale
  | Agent_sdk.Hooks.Edit input -> Keeper_event_queue.Hitl_edited input
;;

let deliver_resolution ~base_path (entry : pending_approval) decision =
  commit_keeper_approval_resolution
    ~base_path
    ~keeper_name:entry.keeper_name
    ~approval_id:entry.id
    ~decision:(hitl_resolution_decision_of_approval_decision decision)
    ~channel:entry.continuation_channel
;;

let resolve_entry
      ?(before_terminal_publish = fun () -> ())
      ~base_path
      (entry : pending_approval)
      ~(source : decision_source)
      (decision : decision)
  =
  let decision_str = approval_decision_to_string decision in
  Log.Keeper.info
    "HITL_APPROVAL_RESOLVED: id=%s keeper=%s tool=%s decision=%s"
    entry.id
    entry.keeper_name
    entry.tool_name
    decision_str;
  audit_approval_event
    ~base_path:base_path
    ~event_type:approval_audit_resolved_event
    ~id:entry.id
    ~keeper_name:entry.keeper_name
    ~tool_name:entry.tool_name
    ?turn_id:entry.turn_id
    ?task_id:entry.task_id
    ?goal_id:entry.goal_id
    ~goal_ids:entry.goal_ids
    ~decision_source:source
    ~decision
    ();
  before_terminal_publish ();
  try
    Sse.broadcast
      (`Assoc
          [ "type", `String approval_sse_resolved_event
          ; ( "payload"
            , `Assoc
                [ "id", `String entry.id
                ; "keeper_name", `String entry.keeper_name
                ; "tool_name", `String entry.tool_name
                ; "decision", `String decision_str
                ] )
          ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    record_queue_failure
      ~keeper_name:entry.keeper_name
      ~site:"broadcast_resolved"
      ~id:entry.id
      ~event_type:approval_audit_resolved_event
      exn
;;

let pending_entry_matches
      (entry : pending_approval)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~turn_id
      ~task_id
      ~goal_id
      ~goal_ids
      ~continuation_channel
  =
  String.equal entry.audit_base_path base_path
  && String.equal entry.keeper_name keeper_name
  && String.equal entry.tool_name tool_name
  && String.equal entry.input_hash input_hash
  && entry.turn_id = turn_id
  && entry.task_id = task_id
  && entry.goal_id = goal_id
  && entry.goal_ids = goal_ids
  && Yojson.Safe.equal
       (Keeper_continuation_channel.to_yojson entry.continuation_channel)
       (Keeper_continuation_channel.to_yojson continuation_channel)
;;

let find_pending_id_in_map
      (map : pending_approval SMap.t)
      ~base_path
      ~keeper_name
      ~tool_name
      ~input_hash
      ~turn_id
      ~task_id
      ~goal_id
      ~goal_ids
      ~continuation_channel
  =
  SMap.fold
    (fun id (entry : pending_approval) acc ->
       match acc with
       | Some _ -> acc
       | None ->
         if
           pending_entry_matches
             entry
             ~base_path
             ~keeper_name
             ~tool_name
             ~input_hash
             ~turn_id
             ~task_id
             ~goal_id
             ~goal_ids
             ~continuation_channel
         then Some id
         else None)
    map
    None
;;

let sort_entries_by_requested_at entries =
  List.sort
    (fun left right ->
       let ts_of_json json = (match Json_util.assoc_member_opt "requested_at" json with Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0) in
       Float.compare (ts_of_json left) (ts_of_json right))
    entries
;;

(* ── Nonblocking submission ───────────────────────────────── *)

let submit_pending
      ~keeper_name
      ~tool_name
      ~input
      ~base_path
      ?turn_id
      ?request_context
      ?task_id
      ?goal_id
      ?(goal_ids = [])
      ?continuation_channel
      ()
  : (string, storage_error) result
  =
  let input_hash = normalized_input_hash input in
  let continuation_channel =
    Option.value continuation_channel ~default:(default_continuation_channel ())
  in
  let stored =
    Stdlib.Mutex.protect pending_store_mu (fun () ->
      let map = Atomic.get pending in
      match
        find_pending_id_in_map
          map
          ~base_path
          ~keeper_name
          ~tool_name
          ~input_hash
          ~turn_id
          ~task_id
          ~goal_id
          ~goal_ids
          ~continuation_channel
      with
      | Some id -> Ok (id, None)
      | None ->
        let id = generate_id () in
        let entry =
          create_entry
            ~id
            ~keeper_name
            ~tool_name
            ~input
            ?turn_id
            ?request_context
            ?task_id
            ?goal_id
            ~goal_ids
            ~continuation_channel
            ~audit_base_path:base_path
            ()
        in
        let updated = SMap.add id entry map in
        (match
           persist_snapshot_unlocked
             ~base_path
             ~pending_map:updated
             ~delivery_map:(Atomic.get deliveries)
         with
         | Error _ as error -> error
         | Ok () ->
           Atomic.set pending updated;
           Ok (id, Some entry)))
  in
  match stored with
  | Error _ as error -> error
  | Ok (id, None) -> Ok id
  | Ok (id, Some entry) ->
    record_pending entry;
    Ok id
;;

(* ── Resolve (operator action) ────────────────────────────── *)

type resolve_error =
  | Not_found of string
  | Already_resolved of string
  | Delivery_failed of
      { approval_id : string
      ; reason : string
      }
  | Persistence_failed of
      { approval_id : string
      ; storage_error : storage_error
      }

let resolve_error_to_string = function
  | Not_found id -> Printf.sprintf "approval %s not found" id
  | Already_resolved id -> Printf.sprintf "approval %s already resolved" id
  | Delivery_failed { approval_id; reason } ->
    Printf.sprintf "approval %s resolution delivery failed: %s" approval_id reason
  | Persistence_failed { approval_id; storage_error } ->
    Printf.sprintf
      "approval %s queue persistence failed: %s"
      approval_id
      (storage_error_to_string storage_error)
;;

module Resolution_claims = Set_util.StringSet

let resolution_claims : Resolution_claims.t Atomic.t =
  Atomic.make Resolution_claims.empty
;;

let rec claim_resolution id =
  let claims = Atomic.get resolution_claims in
  if Resolution_claims.mem id claims
  then false
  else
    let claimed = Resolution_claims.add id claims in
    if Atomic.compare_and_set resolution_claims claims claimed
    then true
    else claim_resolution id
;;

let release_resolution_claim id =
  atomic_update resolution_claims (fun claims -> Resolution_claims.remove id claims)
;;

type journal_error =
  | Journal_not_found
  | Journal_storage of storage_error

let journal_resolution ~id ~decision ~source ~remember_rule ~created_by =
  Stdlib.Mutex.protect pending_store_mu (fun () ->
    let pending_map = Atomic.get pending in
    match SMap.find_opt id pending_map with
    | None -> Error Journal_not_found
    | Some entry ->
      let delivery =
        { entry
        ; decision
        ; source
        ; remember_rule
        ; created_by
        ; grant_consumed = false
        }
      in
      let updated_pending = SMap.remove id pending_map in
      let updated_deliveries = SMap.add id delivery (Atomic.get deliveries) in
      (match
         persist_snapshot_unlocked
           ~base_path:entry.audit_base_path
           ~pending_map:updated_pending
           ~delivery_map:updated_deliveries
       with
       | Error storage_error -> Error (Journal_storage storage_error)
       | Ok () ->
         Atomic.set pending updated_pending;
         Atomic.set deliveries updated_deliveries;
         Ok delivery))
;;

let remove_delivery_from_store delivery =
  Stdlib.Mutex.protect pending_store_mu (fun () ->
    let delivery_map = Atomic.get deliveries in
    let updated_deliveries = SMap.remove delivery.entry.id delivery_map in
    match
      persist_snapshot_unlocked
        ~base_path:delivery.entry.audit_base_path
        ~pending_map:(Atomic.get pending)
        ~delivery_map:updated_deliveries
    with
    | Error _ as error -> error
    | Ok () ->
      Atomic.set deliveries updated_deliveries;
      Ok ())
;;

let approval_decision_equal left right =
  match left, right with
  | Agent_sdk.Hooks.Approve, Agent_sdk.Hooks.Approve -> true
  | Agent_sdk.Hooks.Reject left, Agent_sdk.Hooks.Reject right -> String.equal left right
  | Agent_sdk.Hooks.Edit left, Agent_sdk.Hooks.Edit right -> Yojson.Safe.equal left right
  | (Agent_sdk.Hooks.Approve | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _),
    (Agent_sdk.Hooks.Approve | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _) ->
    false
;;

let remember_rule_for_entry ~base_path ?created_by (entry : pending_approval) =
  try
    match
      upsert_rule
        ~base_path
        ~keeper_name:entry.keeper_name
        ~tool_name:entry.tool_name
        ~input:entry.input
        ?created_by
        ~source_approval_id:entry.id
        ()
    with
    | Ok (rule, created) ->
      if created then audit_rule_event ~base_path ~event_type:"rule_created" rule;
      Ok rule
    | Error reason -> Error reason
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    let reason = Printexc.to_string exn in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ApprovalQueueFailures)
      ~labels:
        [ "keeper", entry.keeper_name
        ; "site", Keeper_approval_queue_failure_site.(to_label Remember_rule)
        ]
      ();
    Log.Keeper.warn
      "approval_queue: remember rule failed id=%s err=%s"
      entry.id
      reason;
    Error
      ({ path = rules_path ~base_path ()
       ; reason
       }
       : rule_store_error)
;;

let remember_rule_for_delivery delivery =
  match delivery.decision, delivery.remember_rule with
  | Agent_sdk.Hooks.Approve, true ->
    (match
       remember_rule_for_entry
         ~base_path:delivery.entry.audit_base_path
         ?created_by:delivery.created_by
         delivery.entry
     with
     | Ok rule -> Ok (Some rule)
     | Error rule_error ->
       Error
         { path = rule_error.path
         ; reason = rule_error.reason
         })
  | (Agent_sdk.Hooks.Approve | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _),
    false ->
    Ok None
  | (Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _), true -> Ok None
;;

let complete_delivery delivery =
  let id = delivery.entry.id in
  let base_path = delivery.entry.audit_base_path in
  if delivery.grant_consumed
  then Ok { remembered_rule = None }
  else
  match deliver_resolution ~base_path delivery.entry delivery.decision with
  | Error reason -> Error (Delivery_failed { approval_id = id; reason })
  | Ok () ->
    (match remember_rule_for_delivery delivery with
     | Error storage_error ->
       Error (Persistence_failed { approval_id = id; storage_error })
     | Ok remembered_rule ->
       let finish () =
         resolve_entry
           ~base_path
           delivery.entry
           ~source:delivery.source
           delivery.decision;
         signal_resolution_after_commit
           ~base_path
           ~keeper_name:delivery.entry.keeper_name
           ~approval_id:id;
         Ok { remembered_rule }
       in
       (match delivery.decision with
        | Agent_sdk.Hooks.Approve ->
          (* Keep the resolved journal entry until the exact Gate request
             consumes it. The wake event is only a correlation message and
             cannot become a second authorization SSOT. *)
          finish ()
        | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _ ->
          (match remove_delivery_from_store delivery with
           | Error storage_error ->
             Error (Persistence_failed { approval_id = id; storage_error })
           | Ok () -> finish ())))
;;

let install_persistence ~base_path =
  (* Snapshot I/O and JSON parsing may yield. Keep them outside the
     process-global commit mutex so a slow filesystem cannot block the Eio
     domain through a contending [Stdlib.Mutex] waiter. The immutable loaded
     maps are merged with the latest in-memory state inside the short commit
     section below. *)
  let loaded_snapshot = load_snapshot_unlocked ~base_path in
  let installed =
    Stdlib.Mutex.protect pending_store_mu (fun () ->
      match loaded_snapshot with
      | Error storage_error ->
        mark_store_unavailable_unlocked ~base_path storage_error;
        Error storage_error
      | Ok (loaded_pending, loaded_deliveries) ->
        let current_pending =
          remove_base_entries ~base_path (Atomic.get pending) Fun.id
        in
        let current_deliveries =
          remove_base_entries
            ~base_path
            (Atomic.get deliveries)
            (fun delivery -> delivery.entry)
        in
        (match
           merge_loaded_map
             ~surface:"gate_pending.pending"
             ~existing:current_pending
             ~loaded:loaded_pending,
           merge_loaded_map
             ~surface:"gate_pending.deliveries"
             ~existing:current_deliveries
             ~loaded:loaded_deliveries
         with
         | Error reason, _ | _, Error reason ->
           let path = pending_store_path ~base_path in
           report_pending_read_drop
             ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
             ~path
             ~detail:reason;
           let error = { path; reason } in
           mark_store_unavailable_unlocked ~base_path error;
           Error error
         | Ok pending_map, Ok delivery_map ->
           (match first_shared_id pending_map delivery_map with
            | Some id ->
              let path = pending_store_path ~base_path in
              let reason =
                Printf.sprintf
                  "gate_pending id %s collides across pending and delivery states"
                  id
              in
              report_pending_read_drop
                ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                ~path
                ~detail:reason;
              let error = { path; reason } in
              mark_store_unavailable_unlocked ~base_path error;
              Error error
            | None ->
              clear_store_unavailable_unlocked ~base_path;
              Atomic.set pending pending_map;
              Atomic.set deliveries delivery_map;
              Ok
                ( SMap.cardinal loaded_pending
                , SMap.bindings loaded_deliveries |> List.map snd ))))
  in
  match installed with
  | Error storage_error -> Error (Install_storage_failed storage_error)
  | Ok (loaded_pending, loaded_deliveries) ->
    let rec replay count failures = function
      | [] ->
        Ok
          { loaded_pending
          ; replayed_deliveries = count
          ; delivery_replay_failures = List.rev failures
          }
      | delivery :: rest ->
        if delivery.grant_consumed
        then replay count failures rest
        else
          (match complete_delivery delivery with
           | Ok _ -> replay (count + 1) failures rest
           | Error error ->
             let failure =
               { approval_id = delivery.entry.id
               ; reason = resolve_error_to_string error
               }
             in
             replay count (failure :: failures) rest)
    in
    replay 0 [] loaded_deliveries
;;

let resolve_with_policy
      ~id
      ~(decision : Agent_sdk.Hooks.approval_decision)
      ?(source = Human_operator)
      ?(remember_rule = false)
      ?created_by
      ()
  : (resolution_result, resolve_error) result
  =
  if not (claim_resolution id)
  then Error (Already_resolved id)
  else
    Fun.protect
      ~finally:(fun () -> release_resolution_claim id)
      (fun () ->
         match SMap.find_opt id (Atomic.get pending) with
         | Some _ ->
           let remember_rule =
             match decision with
             | Agent_sdk.Hooks.Approve -> remember_rule
             | Agent_sdk.Hooks.Reject _ | Agent_sdk.Hooks.Edit _ -> false
           in
           (match
              journal_resolution
                ~id
                ~decision
                ~source
                ~remember_rule
                ~created_by
            with
            | Error Journal_not_found -> Error (Not_found id)
            | Error (Journal_storage storage_error) ->
              Error (Persistence_failed { approval_id = id; storage_error })
            | Ok delivery -> complete_delivery delivery)
         | None ->
           (match SMap.find_opt id (Atomic.get deliveries) with
            | None -> Error (Not_found id)
            | Some delivery ->
              let same_request =
                approval_decision_equal decision delivery.decision
                && source = delivery.source
                && remember_rule = delivery.remember_rule
                && created_by = delivery.created_by
              in
              if same_request
              then complete_delivery delivery
              else Error (Already_resolved id)))
;;

(** Resolve a pending approval. Returns [Ok ()] if found and resolved,
    [Error (Not_found _)] if the id is not in the queue, or
    [Error (Already_resolved _)] if another concurrent resolution owns the
    approval claim. A delivery failure leaves the entry pending for retry.
    Called from the dashboard approval HTTP handler
    ([server_dashboard_http.ml]) and MCP runtime.

    [base_path] is sourced from the entry's captured [audit_base_path]
    rather than threaded from the caller: the convenience wrapper takes
    only an [id], so the entry is the authoritative workspace source
    (RFC-0274 Wave A). *)
let resolve ~id ~(decision : Agent_sdk.Hooks.approval_decision)
  : (unit, resolve_error) result
  =
  match resolve_with_policy ~id ~decision () with
  | Ok _ -> Ok ()
  | Error _ as error -> error
;;

(* ── Query ────────────────────────────────────────────────── *)

(** List all pending approvals as JSON. *)
let list_pending_json () : Yojson.Safe.t =
  let entries =
    SMap.fold
      (fun _id entry acc -> `Assoc (pending_entry_json_fields entry) :: acc)
      (Atomic.get pending)
      []
  in
  `List (sort_entries_by_requested_at entries)
;;

let list_pending_dashboard_json () : Yojson.Safe.t =
  let entries =
    SMap.fold
      (fun _id entry acc ->
         `Assoc
           (pending_entry_json_fields
              ~include_input:true
              entry)
         :: acc)
      (Atomic.get pending)
      []
  in
  `List (sort_entries_by_requested_at entries)
;;

let list_pending_entries () : pending_approval list =
  SMap.fold (fun _id entry acc -> entry :: acc) (Atomic.get pending) []
  |> List.sort (fun left right -> Float.compare left.requested_at right.requested_at)
;;

let pending_entry_detail_json (entry : pending_approval) : Yojson.Safe.t =
  `Assoc
    (pending_entry_json_fields
       ~include_input:true
       entry)
;;

let get_pending_json ~id : Yojson.Safe.t option =
  match SMap.find_opt id (Atomic.get pending) with
  | None -> None
  | Some entry -> Some (pending_entry_detail_json entry)
;;

let pending_count () : int = SMap.cardinal (Atomic.get pending)

let pending_count_for_keeper ~keeper_name : int =
  SMap.fold
    (fun _ (entry : pending_approval) count ->
       if String.equal entry.keeper_name keeper_name then count + 1 else count)
    (Atomic.get pending)
    0
;;

let has_pending_for_keeper ~keeper_name : bool =
  SMap.fold
    (fun _ (entry : pending_approval) acc ->
       acc || String.equal entry.keeper_name keeper_name)
    (Atomic.get pending)
    false
;;
