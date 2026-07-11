(** Keeper_msg_async — fire-and-forget keeper message execution.

    Manages background fibers for keeper_msg turns.
    MCP tool returns immediately with a request_id;
    clients poll keeper_msg_result for completion.

    Completed entries auto-expire from memory after [max_age_sec] to prevent
    memory leaks. Non-terminal entries remain queryable until they either
    complete or are recovered from disk as lost after a process restart. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type request_status =
  | Queued
  | Running
  | Lost of { reason : string }
  | Cancelled of
      { reason : string
      ; cancelled_by : string
      }
  | Persistence_failed of
      { attempted_status : string
      ; reason : string
      }
  | Done of
      { ok : bool
      ; body : string
      }

type entry =
  { request_id : string
  ; keeper_name : string
  ; base_path : string
  ; submitted_by : string
  ; status : request_status
  ; submitted_at : float
  ; completed_at : float option
  }

type access_rejection =
  | Invalid_base_path of { reason : string }
  | Invalid_caller
  | Invalid_request_id
  | Caller_mismatch

(** Outcome of looking up a request record. [Absent] means no record exists
    (never submitted, or already GC'd); pollers can stop polling or resubmit.
    [Unreadable] means a record file exists but cannot be decoded — the
    request WAS accepted, but its result cannot be recovered. *)
type load_result =
  | Found of entry
  | Absent
  | Unreadable of string
  | Rejected of access_rejection

type submit_error =
  | Submit_rejected of access_rejection
  | Invalid_timeout of { reason : string }
  | Initial_persistence_failed of { reason : string }
  | Background_switch_unavailable of { reason : string }
  | Background_fork_failed of
      { request_id : string
      ; reason : string
      }

type cancel_result =
  | Cancelled_request
  | Cancel_not_found
  | Cancel_unreadable of string
  | Cancel_rejected of access_rejection
  | Cancel_already_terminal of request_status
  | Cancel_persistence_failed of { reason : string }
  | Cancel_worker_signal_failed of { reason : string }

(* [Worker_cancelled], not [Cancelled]: [request_status] above already binds
   an unqualified [Cancelled] constructor with the same field names in this
   module. A same-named constructor here would shadow it for every
   unqualified use below and risk silently constructing the wrong type. *)
type worker_cancel_source =
  | Operator_request
  | Runtime_cancellation

let worker_cancel_source_to_string = function
  | Operator_request -> "operator"
  | Runtime_cancellation -> "runtime"
;;

type worker_abort_reason =
  | Timeout of { timeout_sec : float }
  | Worker_cancelled of
      { cancelled_by : worker_cancel_source
      ; reason : string
      }

module Request_key = struct
  type t =
    { base_path : string
    ; submitted_by : string
    ; request_id : string
    }

  let equal a b =
    String.equal a.base_path b.base_path
    && String.equal a.submitted_by b.submitted_by
    && String.equal a.request_id b.request_id
  ;;

  let hash key = Hashtbl.hash (key.base_path, key.submitted_by, key.request_id)
end

module Request_table = Hashtbl.Make (Request_key)

let mu = Eio.Mutex.create ()
let pending : entry Request_table.t = Request_table.create 16
let active_switches : Eio.Switch.t Request_table.t = Request_table.create 16
exception CancelledByOperator
exception Worker_timeout of float
exception Worker_preempted of string
let max_age_sec = Masc_time_constants.hour
let record_schema_version = 2

let effective_timeout_sec ?timeout_sec () =
  match timeout_sec with
  | Some timeout_sec -> timeout_sec
  | None -> Keeper_runtime_resolved.turn_timeout_sec ()
;;

let resolve_timeout_sec ?timeout_sec () =
  let value = effective_timeout_sec ?timeout_sec () in
  if Float.is_finite value && value > 0.0
  then Ok value
  else
    Error
      (Invalid_timeout
         { reason =
             Printf.sprintf
               "keeper_msg timeout_sec must be finite and greater than zero (resolved=%g)"
               value
         })
;;

let server_background_switch () =
  match Eio_context.get_root_switch_opt () with
  | Some sw -> Ok sw
  | None ->
    Error
      (Background_switch_unavailable
         { reason = "keeper_msg requires the server root switch (unavailable)" })
;;

let request_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests"
;;

let canonical_base_path base_path =
  let normalized = Workspace_utils_backend_setup.normalize_base_path base_path in
  if String.equal normalized ""
  then Error (Invalid_base_path { reason = "base_path is empty" })
  else
    try Ok (Fs_compat.realpath normalized) with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Error
        (Invalid_base_path
           { reason =
               Printf.sprintf
                 "cannot canonicalize base_path: %s"
                 (Printexc.to_string exn)
           })
;;

let validate_caller caller =
  let trimmed = String.trim caller in
  if String.equal trimmed "" || not (String.equal caller trimmed)
  then Error Invalid_caller
  else Ok caller
;;

let resolve_access_identity ~base_path ~caller =
  let* base_path = canonical_base_path base_path in
  let* submitted_by = validate_caller caller in
  Ok (base_path, submitted_by)
;;

let request_key ~base_path ~submitted_by ~request_id : Request_key.t =
  { base_path; submitted_by; request_id }
;;

let max_request_id_len = 128

let is_safe_request_id request_id =
  let len = String.length request_id in
  if len = 0
  then false
  else if request_id = "." || request_id = ".."
  then false
  else if len > max_request_id_len
  then false
  else (
    let rec loop i =
      if i = len
      then true
      else (
        match request_id.[i] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' -> loop (i + 1)
        | _ -> false)
    in
    loop 0)
;;

let record_path ~base_path ~request_id =
  if is_safe_request_id request_id
  then Some (Filename.concat (request_dir ~base_path) (request_id ^ ".json"))
  else None
;;

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Lost _ -> "lost"
  | Cancelled _ -> "cancelled"
  | Persistence_failed _ -> "persistence_failed"
  | Done { ok = true; _ } -> "done"
  | Done { ok = false; _ } -> "error"
;;

let access_rejection_to_json = function
  | Invalid_base_path { reason } ->
    `Assoc
      [ "error", `String "invalid_base_path"
      ; "message", `String reason
      ]
  | Invalid_caller ->
    `Assoc
      [ "error", `String "invalid_caller"
      ; ( "message"
        , `String "caller identity must be non-empty and free of surrounding whitespace" )
      ]
  | Invalid_request_id ->
    `Assoc
      [ "error", `String "invalid_request_id"
      ; "message", `String "request_id contains invalid characters or length"
      ]
  | Caller_mismatch ->
    `Assoc
      [ "error", `String "request_caller_mismatch"
      ; "message", `String "request does not belong to the authenticated caller"
      ]
;;

let submit_error_to_json = function
  | Submit_rejected rejection -> access_rejection_to_json rejection
  | Invalid_timeout { reason } ->
    `Assoc
      [ "error", `String "invalid_timeout"
      ; "message", `String reason
      ]
  | Initial_persistence_failed { reason } ->
    `Assoc
      [ "error", `String "request_persistence_failed"
      ; "message", `String reason
      ]
  | Background_switch_unavailable { reason } ->
    `Assoc
      [ "error", `String "background_switch_unavailable"
      ; "message", `String reason
      ]
  | Background_fork_failed { request_id; reason } ->
    `Assoc
      [ "error", `String "request_background_start_failed"
      ; "request_id", `String request_id
      ; "status", `String "lost"
      ; "message", `String reason
      ]
;;

let cancel_result_to_json ~request_id = function
  | Cancelled_request ->
    `Assoc
      [ "request_id", `String request_id
      ; "status", `String "cancelled"
      ; "message", `String "Keeper turn cancelled successfully."
      ]
  | Cancel_not_found ->
    `Assoc
      [ "error", `String "request_id_not_found"
      ; "request_id", `String request_id
      ]
  | Cancel_unreadable reason ->
    `Assoc
      [ "error", `String "request_record_unreadable"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
  | Cancel_rejected rejection ->
    `Assoc
      [ "error", `String "request_access_rejected"
      ; "request_id", `String request_id
      ; "reason", access_rejection_to_json rejection
      ]
  | Cancel_already_terminal status ->
    `Assoc
      [ "error", `String "request_already_terminal"
      ; "request_id", `String request_id
      ; "status", `String (status_to_string status)
      ]
  | Cancel_persistence_failed { reason } ->
    `Assoc
      [ "error", `String "cancellation_persistence_failed"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
  | Cancel_worker_signal_failed { reason } ->
    `Assoc
      [ "error", `String "cancellation_worker_signal_failed"
      ; "request_id", `String request_id
      ; "message", `String reason
      ]
;;

let entry_record_to_json (e : entry) : Yojson.Safe.t =
  let fields =
    [ "schema_version", `Int record_schema_version
    ; "request_id", `String e.request_id
    ; "keeper_name", `String e.keeper_name
    ; "base_path", `String e.base_path
    ; "submitted_by", `String e.submitted_by
    ; "status", `String (status_to_string e.status)
    ; "submitted_at", `Float e.submitted_at
    ]
  in
  let fields =
    match e.completed_at with
    | Some t -> fields @ [ "completed_at", `Float t ]
    | None -> fields
  in
  let fields =
    match e.status with
    | Done { ok; body } -> fields @ [ "ok", `Bool ok; "body", `String body ]
    | Lost { reason } -> fields @ [ "reason", `String reason ]
    | Cancelled { reason; cancelled_by } ->
      fields @ [ "reason", `String reason; "cancelled_by", `String cancelled_by ]
    | Persistence_failed { attempted_status; reason } ->
      fields
      @ [ "attempted_status", `String attempted_status; "reason", `String reason ]
    | Queued | Running -> fields
  in
  `Assoc fields
;;

let string_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let float_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let bool_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Bool value) -> Some value
  | _ -> None
;;

let int_member name json =
  match Json_util.assoc_member_opt name json with
  | Some (`Int value) -> Some value
  | _ -> None
;;

let required_string name json =
  match string_member name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "record is missing required string field %S" name)
;;

let required_float name json =
  match float_member name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "record is missing required numeric field %S" name)
;;

let required_bool name json =
  match bool_member name json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "record is missing required boolean field %S" name)
;;

let required_completed_at json =
  match float_member "completed_at" json with
  | Some value -> Ok (Some value)
  | None -> Error "terminal record is missing required numeric field \"completed_at\""
;;

let validate_record_fields ~status_fields json =
  let common_fields =
    [ "schema_version"
    ; "request_id"
    ; "keeper_name"
    ; "base_path"
    ; "submitted_by"
    ; "status"
    ; "submitted_at"
    ]
  in
  let allowed = common_fields @ status_fields in
  match json with
  | `Assoc fields ->
    let rec loop seen = function
      | [] -> Ok ()
      | (name, _) :: rest ->
        if List.mem name seen
        then Error (Printf.sprintf "record contains duplicate field %S" name)
        else if not (List.mem name allowed)
        then Error (Printf.sprintf "record contains unsupported field %S" name)
        else loop (name :: seen) rest
    in
    loop [] fields
  | _ -> Error "record must be a JSON object"
;;

let decode_status ~tag json =
  match tag with
  | "queued" -> Ok (Queued, None)
  | "running" -> Ok (Running, None)
  | "lost" ->
    let* reason = required_string "reason" json in
    let* completed_at = required_completed_at json in
    Ok (Lost { reason }, completed_at)
  | "cancelled" ->
    let* reason = required_string "reason" json in
    let* cancelled_by = required_string "cancelled_by" json in
    let* completed_at = required_completed_at json in
    Ok (Cancelled { reason; cancelled_by }, completed_at)
  | "persistence_failed" ->
    let* attempted_status = required_string "attempted_status" json in
    let* reason = required_string "reason" json in
    let* completed_at = required_completed_at json in
    Ok (Persistence_failed { attempted_status; reason }, completed_at)
  | ("done" | "error") as terminal_tag ->
    let* ok = required_bool "ok" json in
    let* body = required_string "body" json in
    let* completed_at = required_completed_at json in
    if Bool.equal ok (String.equal terminal_tag "done")
    then Ok (Done { ok; body }, completed_at)
    else
      Error
        (Printf.sprintf
           "record status %S disagrees with required ok=%b"
           terminal_tag
           ok)
  | other -> Error (Printf.sprintf "unknown status %S in record" other)
;;

let entry_of_record_json ~base_path ~request_id:expected_request_id json :
    (entry, string) result =
  let* schema_version =
    match int_member "schema_version" json with
    | Some version -> Ok version
    | None -> Error "record is missing required integer field \"schema_version\""
  in
  let* () =
    if Int.equal schema_version record_schema_version
    then Ok ()
    else
      Error
        (Printf.sprintf
           "unsupported keeper_msg request schema_version=%d (expected %d)"
           schema_version
           record_schema_version)
  in
  let* request_id = required_string "request_id" json in
  let* () =
    if String.equal request_id expected_request_id
    then Ok ()
    else
      Error
        (Printf.sprintf
           "record request_id %S does not match filename request_id %S"
           request_id
           expected_request_id)
  in
  let* keeper_name = required_string "keeper_name" json in
  let* persisted_base_path = required_string "base_path" json in
  let* submitted_by = required_string "submitted_by" json in
  let* () =
    let trimmed = String.trim submitted_by in
    if String.equal trimmed "" || not (String.equal submitted_by trimmed)
    then Error "record submitted_by is not a canonical caller identity"
    else Ok ()
  in
  let* () =
    if String.equal persisted_base_path base_path
    then Ok ()
    else
      Error "record base_path identity does not match request store root"
  in
  let* status_tag = required_string "status" json in
  let* submitted_at = required_float "submitted_at" json in
  let* status, completed_at = decode_status ~tag:status_tag json in
  let status_fields =
    match status with
    | Queued | Running -> []
    | Lost _ -> [ "completed_at"; "reason" ]
    | Cancelled _ -> [ "completed_at"; "reason"; "cancelled_by" ]
    | Persistence_failed _ -> [ "completed_at"; "attempted_status"; "reason" ]
    | Done _ -> [ "completed_at"; "ok"; "body" ]
  in
  let* () = validate_record_fields ~status_fields json in
  Ok
    { request_id
    ; keeper_name
    ; base_path = persisted_base_path
    ; submitted_by
    ; status
    ; submitted_at
    ; completed_at
    }
;;

let persist_entry (entry : entry) =
  match record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Error "generated request_id is unsafe for persistence"
  | Some path -> Keeper_fs.save_json_atomic path (entry_record_to_json entry)
;;

let load_record_canonical ~base_path ~request_id : load_result =
  match record_path ~base_path ~request_id with
  | None -> Rejected Invalid_request_id
  | Some path ->
    if not (Fs_compat.file_exists path)
    then Absent
    else (
      let decoded =
        try
          Fs_compat.load_file path
          |> Yojson.Safe.from_string
          |> entry_of_record_json ~base_path ~request_id
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error (Printexc.to_string exn)
      in
      match decoded with
      | Ok entry -> Found entry
      | Error reason ->
        Log.Keeper.warn
          "keeper_msg_async: load failed request_id=%s path=%s error=%s"
          request_id
          path
          reason;
        Unreadable reason)
;;

let load_record ~base_path ~request_id : load_result =
  match canonical_base_path base_path with
  | Error rejection -> Rejected rejection
  | Ok base_path -> load_record_canonical ~base_path ~request_id
;;

let observe_persist_error ~operation (entry : entry) = function
  | Ok () -> Ok ()
  | Error reason ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string FsFailures)
      ~labels:[ "subsystem", "keeper_msg_async"; "operation", operation ]
      ();
    Log.Keeper.error
      "keeper_msg_async: %s persist failed request_id=%s path_identity=%s error=%s"
      operation
      entry.request_id
      entry.base_path
      reason;
    Error reason
;;

let has_suffix ~suffix value =
  let value_len = String.length value in
  let suffix_len = String.length suffix in
  value_len >= suffix_len
  && String.equal (String.sub value (value_len - suffix_len) suffix_len) suffix
;;

let request_id_of_record_filename name =
  let suffix = ".json" in
  if has_suffix ~suffix name
  then Some (String.sub name 0 (String.length name - String.length suffix))
  else None
;;

let should_gc_disk_record ~now (entry : entry) =
  match entry.status with
  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
    now -. entry.submitted_at > max_age_sec
  | Queued | Running -> false
;;

let remove_record_file path =
  try
    Sys.remove path;
    true
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_msg_async: gc remove failed path=%s error=%s"
      path
      (Printexc.to_string exn);
    false
;;

let gc_stale_disk_canonical ~base_path =
  let dir = request_dir ~base_path in
  let now = Unix.gettimeofday () in
  try
    if (not (Sys.file_exists dir)) || not (Sys.is_directory dir)
    then 0
    else
      Sys.readdir dir
      |> Array.fold_left
           (fun removed name ->
              match request_id_of_record_filename name with
              | None -> removed
              | Some request_id ->
                let path = Filename.concat dir name in
                if Sys.is_directory path
                then removed
                else (
                  match load_record_canonical ~base_path ~request_id with
                  | Found entry when should_gc_disk_record ~now entry ->
                    if remove_record_file path then removed + 1 else removed
                  (* Unreadable records are kept so pollers can still observe
                     that the request was accepted but its result is lost. *)
                  | Found _ | Absent | Unreadable _ | Rejected _ -> removed))
           0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_msg_async: gc scan failed base_path=%s dir=%s error=%s"
      base_path
      dir
      (Printexc.to_string exn);
    0
;;

let gc_stale_disk ~base_path =
  match canonical_base_path base_path with
  | Ok base_path -> gc_stale_disk_canonical ~base_path
  | Error rejection ->
    Log.Keeper.error
      "keeper_msg_async: gc rejected base_path error=%s"
      (Yojson.Safe.to_string (access_rejection_to_json rejection));
    0
;;

let mark_lost_after_recovery (entry : entry) =
  let reason =
    "keeper_msg request was accepted but no live worker owns it; the server may have \
     restarted or evicted the request before terminal result"
  in
  let lost =
    { entry with status = Lost { reason }; completed_at = Some (Unix.gettimeofday ()) }
  in
  match persist_entry lost |> observe_persist_error ~operation:"recovery" lost with
  | Ok () -> Ok lost
  | Error reason -> Error reason
;;

let request_has_live_worker ~base_path ~submitted_by request_id =
  let key = request_key ~base_path ~submitted_by ~request_id in
  Eio.Mutex.use_ro mu (fun () -> Request_table.mem pending key)
;;

let recover_lost_disk_records_canonical ~base_path =
  let dir = request_dir ~base_path in
  try
    if (not (Sys.file_exists dir)) || not (Sys.is_directory dir)
    then 0
    else
      Sys.readdir dir
      |> Array.fold_left
           (fun recovered name ->
              match request_id_of_record_filename name with
              | None -> recovered
              | Some request_id ->
                let path = Filename.concat dir name in
                if Sys.is_directory path
                then recovered
                else (
                  match load_record_canonical ~base_path ~request_id with
                  | Found ({ status = Queued | Running; _ } as entry) ->
                    if
                      request_has_live_worker
                        ~base_path
                        ~submitted_by:entry.submitted_by
                        request_id
                    then recovered
                    else (
                      (* See mark_lost_after_recovery: persisted status change is enough. *)
                      match mark_lost_after_recovery entry with
                      | Ok _ -> recovered + 1
                      | Error _ -> recovered)
                  | Found _ | Absent | Unreadable _ | Rejected _ -> recovered))
           0
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "keeper_msg_async: recovery scan failed base_path=%s dir=%s error=%s"
      base_path
      dir
      (Printexc.to_string exn);
    0
;;

let recover_lost_disk_records ~base_path =
  match canonical_base_path base_path with
  | Ok base_path -> recover_lost_disk_records_canonical ~base_path
  | Error rejection ->
    Log.Keeper.error
      "keeper_msg_async: recovery rejected base_path error=%s"
      (Yojson.Safe.to_string (access_rejection_to_json rejection));
    0
;;

let generate_request_id () = Random_id.prefixed ~prefix:"kmsg-" ~bytes:16

let with_lock f = Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())

let gc_stale () =
  let now = Unix.gettimeofday () in
  with_lock (fun () ->
    Request_table.fold
      (fun key entry acc ->
         match entry.status with
         | (Done _ | Lost _ | Cancelled _ | Persistence_failed _)
           when now -. entry.submitted_at > max_age_sec -> key :: acc
         | Queued | Running | Done _ | Lost _ | Cancelled _ | Persistence_failed _ -> acc)
      pending
      []
    |> List.iter (fun key -> Request_table.remove pending key))
;;

let is_terminal_status = function
  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ -> true
  | Queued | Running -> false
;;

let install_persistence_failure_if_current key (attempted_entry : entry) reason =
  let failure_entry =
    { attempted_entry with
      status =
        Persistence_failed
          { attempted_status = status_to_string attempted_entry.status; reason }
    ; completed_at = Some (Unix.gettimeofday ())
    }
  in
  let installed =
    with_lock (fun () ->
      match Request_table.find_opt pending key with
      | Some current when current == attempted_entry ->
        Request_table.replace pending key failure_entry;
        true
      | Some _ | None -> false)
  in
  if installed
  then
    ignore
      (persist_entry failure_entry
       |> observe_persist_error ~operation:"persistence_failure_marker" failure_entry
        : (unit, string) result)
;;

let set_status ?(preserve_terminal = false) key status =
  let to_persist =
    with_lock (fun () ->
      match Request_table.find_opt pending key with
      | Some entry when preserve_terminal && is_terminal_status entry.status -> None
      | Some entry ->
        let completed_at =
          match status with
          | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
            (* NDT-OK: completed_at is observational wall-clock metadata for
               terminal request records; state transitions are status-derived. *)
            Some (Unix.gettimeofday ())
          | _ -> None
        in
        let updated = { entry with status; completed_at } in
        Request_table.replace pending key updated;
        Some updated
      | None -> None)
  in
  Option.iter
    (fun entry ->
       match
         persist_entry entry |> observe_persist_error ~operation:"status_update" entry
       with
       | Ok () -> ()
       | Error reason -> install_persistence_failure_if_current key entry reason)
    to_persist
;;

let set_status_protected ?preserve_terminal key status =
  Eio.Cancel.protect (fun () -> set_status ?preserve_terminal key status)
;;

let clear_active_switch key =
  with_lock (fun () -> Request_table.remove active_switches key)
;;

let cancelled_status ~cancelled_by reason =
  Cancelled { reason; cancelled_by }
;;

let operator_cancelled_status () =
  cancelled_status
    ~cancelled_by:"operator"
    "keeper_msg request was cancelled by operator"
;;

let runtime_cancelled_status () =
  cancelled_status
    ~cancelled_by:"runtime"
    "keeper_msg worker was cancelled by runtime before terminal result"
;;

let timeout_done_status ~request_id ~keeper_name ~timeout_sec =
  Done
    { ok = false
    ; body =
        Yojson.Safe.to_string
          (`Assoc
              [ "error", `String "keeper_msg_timeout"
              ; "message", `String "keeper_msg request exceeded timeout_sec"
              ; "request_id", `String request_id
              ; "keeper_name", `String keeper_name
              ; "timeout_sec", `Float timeout_sec
              ])
    }
;;

let submit ?clock ?timeout_sec ?on_worker_aborted ~background_sw ~base_path ~caller
    ~(f : Eio.Switch.t -> tool_result) ~keeper_name () : (string, submit_error) result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Error (Submit_rejected rejection)
  | Ok (base_path, submitted_by) ->
    let* worker_timeout_sec = resolve_timeout_sec ?timeout_sec () in
    gc_stale ();
    ignore (gc_stale_disk_canonical ~base_path);
    let request_id = generate_request_id () in
    let entry =
      { request_id
      ; keeper_name
      ; base_path
      ; submitted_by
      ; status = Queued
      ; submitted_at = Unix.gettimeofday ()
      ; completed_at = None
      }
    in
    let key = request_key ~base_path ~submitted_by ~request_id in
    with_lock (fun () -> Request_table.replace pending key entry);
    (match persist_entry entry |> observe_persist_error ~operation:"initial" entry with
     | Error reason ->
       with_lock (fun () -> Request_table.remove pending key);
       (match record_path ~base_path ~request_id with
        | Some path when Fs_compat.file_exists path ->
          ignore (remove_record_file path : bool)
        | Some _ | None -> ());
       Error (Initial_persistence_failed { reason })
     | Ok () ->
       (match
          Eio.Fiber.fork_daemon ~sw:background_sw (fun () ->
    set_status_protected ~preserve_terminal:true key Running;
    (* [f] owns any terminal signal it emits on its own side channels while
       it runs (e.g. push_worker_event in server_routes_http_keeper_stream's
       process_single_turn). Every catch arm below fires exactly when [f] was
       cut off before reaching that code, so the caller's channel would
       otherwise see nothing — see masc#23924. Eio.Cancel.protect matches
       set_status_protected above: at these catch sites the ambient switch
       may still be tearing down, so an unprotected call could itself be
       cancelled before the callback runs. *)
    let notify_aborted reason =
      match on_worker_aborted with
      | None -> ()
      | Some cb ->
        Eio.Cancel.protect (fun () ->
          match cb reason with
          | () -> ()
          | exception exn ->
            Log.Keeper.error
              "keeper_msg_async: on_worker_aborted callback failed request_id=%s error=%s"
              request_id
              (Printexc.to_string exn);
            raise exn)
    in
    let run_worker_with_timeout request_sw =
      match clock with
      | Some clock ->
        (try Eio.Time.with_timeout_exn clock worker_timeout_sec (fun () -> f request_sw) with
         | Eio.Time.Timeout ->
           let status =
             timeout_done_status ~request_id ~keeper_name ~timeout_sec:worker_timeout_sec
           in
           set_status_protected ~preserve_terminal:true key status;
           notify_aborted (Timeout { timeout_sec = worker_timeout_sec });
           raise (Worker_timeout worker_timeout_sec))
      | None -> f request_sw
    in
    let result =
      try
        Eio.Switch.run (fun req_sw ->
          let admission =
            with_lock (fun () ->
              Request_table.replace active_switches key req_sw;
              match Request_table.find_opt pending key with
              | Some { status = Queued | Running; _ } -> `Run
              | Some { status = Cancelled _; _ } -> `Operator_cancelled
              | Some entry ->
                `Preempted
                  (Printf.sprintf
                     "keeper_msg worker cannot start from terminal status=%s"
                     (status_to_string entry.status))
              | None -> `Preempted "keeper_msg request disappeared before worker start")
          in
          (match admission with
           | `Run -> ()
           | `Operator_cancelled -> raise CancelledByOperator
           | `Preempted reason -> raise (Worker_preempted reason));
          let result = run_worker_with_timeout req_sw in
          Done { ok = tool_result_success result; body = tool_result_body result })
      with
      | Worker_timeout timeout_sec ->
        timeout_done_status ~request_id ~keeper_name ~timeout_sec
      | CancelledByOperator ->
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            notify_aborted
              (Worker_cancelled
                 { cancelled_by = Operator_request
                 ; reason = "keeper_msg request was cancelled by operator"
                 }));
        operator_cancelled_status ()
      | Worker_preempted reason ->
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            notify_aborted
              (Worker_cancelled { cancelled_by = Runtime_cancellation; reason }));
        runtime_cancelled_status ()
      | Eio.Cancel.Cancelled _ as e ->
        set_status_protected ~preserve_terminal:true key (runtime_cancelled_status ());
        (* [notify_aborted] re-raises callback exceptions now that delivery is
           fail closed, so the switch-table release must be exception-safe or
           every failed callback leaks a stale [active_switches] entry.
           [clear_active_switch] is a mutex-guarded [Request_table.remove] and cannot
           itself raise, so the finally carries no [Finally_raised] risk. *)
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            notify_aborted
              (Worker_cancelled
                 { cancelled_by = Runtime_cancellation
                 ; reason =
                     "keeper_msg worker was cancelled by runtime before terminal result"
                 }));
        raise e
      | exn ->
        Done
          { ok = false
          ; body = Printf.sprintf "keeper_msg failed: %s" (Printexc.to_string exn)
          }
    in
    set_status_protected ~preserve_terminal:true key result;
    clear_active_switch key;
    `Stop_daemon)
        with
        | () -> Ok request_id
        | exception exn ->
          let reason =
            Printf.sprintf
              "keeper_msg request was persisted but its background worker could not start: %s"
              (Printexc.to_string exn)
          in
          set_status_protected ~preserve_terminal:true key (Lost { reason });
          Error (Background_fork_failed { request_id; reason })))
;;

(** Exact owner check for both the process-global table and persisted rows. *)
let owner_rejection ~caller (entry : entry) =
  if not (String.equal entry.submitted_by caller)
  then Some Caller_mismatch
  else None
;;

(** Poll for the result of an async keeper_msg request. *)
let poll ~base_path ~caller request_id : load_result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Rejected Invalid_request_id
    else (
      let key = request_key ~base_path ~submitted_by:caller ~request_id in
      match Eio.Mutex.use_ro mu (fun () -> Request_table.find_opt pending key) with
      | Some entry ->
        (match owner_rejection ~caller entry with
         | Some rejection -> Rejected rejection
         | None -> Found entry)
      | None ->
        ignore (gc_stale_disk_canonical ~base_path);
        (match load_record_canonical ~base_path ~request_id with
         | Found entry ->
           (match owner_rejection ~caller entry with
            | Some rejection -> Rejected rejection
            | None ->
              (match entry.status with
               | Queued | Running ->
                 (match mark_lost_after_recovery entry with
                  | Ok lost -> Found lost
                  | Error reason -> Unreadable reason)
               | Done _ | Lost _ | Cancelled _ | Persistence_failed _ -> Found entry))
         | (Absent | Unreadable _ | Rejected _) as result -> result))
;;

(** List only this caller lane; cross-lane rows are intentionally omitted. *)
let list_for_keeper ~base_path ~caller ?keeper_name () :
    (entry list, access_rejection) result =
  let* base_path, caller = resolve_access_identity ~base_path ~caller in
  let entries =
    Eio.Mutex.use_ro mu (fun () ->
      Request_table.fold
        (fun _id entry acc ->
           if Option.is_some (owner_rejection ~caller entry)
           then acc
           else
             match keeper_name with
             | Some name when not (String.equal entry.keeper_name name) -> acc
             | Some _ | None -> entry :: acc)
        pending
        [])
    |> List.sort (fun a b -> compare b.submitted_at a.submitted_at)
  in
  Ok entries
;;

let entry_to_json (e : entry) : Yojson.Safe.t =
  let fields =
    [ "request_id", `String e.request_id
    ; "keeper_name", `String e.keeper_name
    ; "submitted_by", `String e.submitted_by
    ; "status", `String (status_to_string e.status)
    ; "submitted_at", `Float e.submitted_at
    ]
  in
  let fields =
    match e.completed_at with
    | Some t -> fields @ [ "completed_at", `Float t ]
    | None ->
      let elapsed = Unix.gettimeofday () -. e.submitted_at in
      fields @ [ "elapsed_sec", `Float elapsed ]
  in
  let fields =
    match e.status with
    | Done { ok; body } ->
      fields
      @ [ "ok", `Bool ok
        ; ( "result"
          , try Yojson.Safe.from_string body with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | Yojson.Json_error _ -> `String body )
        ]
    | Lost { reason } ->
      fields
      @ [ "ok", `Bool false
        ; "result", `Assoc [ "error", `String "request_lost"; "reason", `String reason ]
        ]
    | Cancelled { reason; cancelled_by } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "cancelled", `Bool true
              ; "reason", `String reason
              ; "cancelled_by", `String cancelled_by
              ] )
        ]
    | Persistence_failed { attempted_status; reason } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "error", `String "request_persistence_failed"
              ; "attempted_status", `String attempted_status
              ; "reason", `String reason
              ] )
        ]
    | _ -> fields
  in
  `Assoc fields
;;

let cancelled_entry (entry : entry) =
  { entry with
    status = operator_cancelled_status ()
  ; completed_at = Some (Unix.gettimeofday ())
  }
;;

let cancel ~base_path ~caller request_id : cancel_result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Cancel_rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Cancel_rejected Invalid_request_id
    else (
      let key = request_key ~base_path ~submitted_by:caller ~request_id in
      let in_memory_decision =
        with_lock (fun () ->
          match Request_table.find_opt pending key with
          | None -> `Load_disk
          | Some entry ->
            (match owner_rejection ~caller entry with
             | Some rejection -> `Rejected rejection
             | None when is_terminal_status entry.status -> `Terminal entry.status
             | None ->
               let updated = cancelled_entry entry in
               Request_table.replace pending key updated;
               `Cancel (updated, Request_table.find_opt active_switches key)))
      in
      match in_memory_decision with
      | `Rejected rejection -> Cancel_rejected rejection
      | `Terminal status -> Cancel_already_terminal status
      | `Cancel (entry, request_sw) ->
        let persisted =
          persist_entry entry |> observe_persist_error ~operation:"operator_cancel" entry
        in
        (match persisted with
         | Ok () -> ()
         | Error reason -> install_persistence_failure_if_current key entry reason);
        let signalled =
          match request_sw with
          | None -> Ok ()
          | Some sw ->
            (try
               Eio.Switch.fail sw CancelledByOperator;
               with_lock (fun () -> Request_table.remove active_switches key);
               Ok ()
             with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn -> Error (Printexc.to_string exn))
        in
        (match persisted, signalled with
         | Ok (), Ok () -> Cancelled_request
         | Error reason, _ -> Cancel_persistence_failed { reason }
         | Ok (), Error reason -> Cancel_worker_signal_failed { reason })
      | `Load_disk ->
        (match load_record_canonical ~base_path ~request_id with
         | Absent -> Cancel_not_found
         | Unreadable reason -> Cancel_unreadable reason
         | Rejected rejection -> Cancel_rejected rejection
         | Found entry ->
           (match owner_rejection ~caller entry with
            | Some rejection -> Cancel_rejected rejection
            | None when is_terminal_status entry.status ->
              Cancel_already_terminal entry.status
            | None ->
              let entry = cancelled_entry entry in
              (match
                 persist_entry entry
                 |> observe_persist_error ~operation:"operator_cancel_disk" entry
               with
               | Ok () -> Cancelled_request
               | Error reason -> Cancel_persistence_failed { reason }))))
;;

module For_testing = struct
  let record_schema_version = record_schema_version
  let is_safe_request_id = is_safe_request_id
  let forget ~base_path ~caller ~request_id =
    match resolve_access_identity ~base_path ~caller with
    | Error _ -> ()
    | Ok (base_path, submitted_by) ->
      let key = request_key ~base_path ~submitted_by ~request_id in
      with_lock (fun () -> Request_table.remove pending key)
  ;;

  let clear () =
    with_lock (fun () ->
      Request_table.clear pending;
      Request_table.clear active_switches)
  ;;
  let record_path = record_path
  let load_record = load_record
  let gc_stale_disk = gc_stale_disk
  let recover_lost_disk_records = recover_lost_disk_records
  let active_switch_count () =
    Eio.Mutex.use_ro mu (fun () -> Request_table.length active_switches)
  ;;

  let effective_timeout_sec = effective_timeout_sec
end
