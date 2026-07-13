(** Keeper_msg_async — fire-and-forget keeper message execution.

    Manages background fibers for keeper_msg turns.
    MCP tool returns immediately with a request_id;
    clients poll keeper_msg_result for completion.

    Process memory owns active request workers only. Terminal entries leave the
    active index after a durable namespace move into the terminal partition and
    remain queryable by exact request id until an explicit cleanup policy
    removes them. Startup recovery scans only the active partition; historical
    terminal volume is not on the synchronous recovery path. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let ( let* ) = Result.bind

type request_status =
  | Queued
  | Running
  | Cancelling of
      { reason : string
      ; cancelled_by : string
      }
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

(** Outcome of looking up a request record. [Absent] means no accepted record
    exists for this identity (or it was explicitly removed); it is not evidence
    that resubmission is safe.
    [Unreadable] means a record file exists but cannot be decoded — the
    request WAS accepted, but its result cannot be recovered. *)
type load_result =
  | Found of entry
  | Absent
  | Unreadable of string
  | Rejected of access_rejection

type recovery_report =
  { lost : int
  ; migrated : int
  ; cleaned : int
  ; deferred : int
  ; unreadable : int
  ; failed : int
  ; store_errors : recovery_store_error list
  ; record_errors : recovery_record_error list
  }

and recovery_store =
  | Active_store
  | Legacy_store

and recovery_store_error =
  { store : recovery_store
  ; path : string
  ; reason : string
  }

and recovery_record_error =
  { store : recovery_store
  ; path : string
  ; request_id : string
  ; keeper_name : string option
  ; kind : recovery_record_error_kind
  }

and recovery_record_error_kind =
  | Recovery_record_unreadable of string
  | Recovery_record_missing
  | Recovery_record_not_file
  | Recovery_record_rejected of access_rejection
  | Recovery_source_ambiguity of string
  | Recovery_terminal_integrity of string
  | Recovery_persistence_failed of string
  | Recovery_source_cleanup_failed
  | Recovery_entry_exception of string

type submit_error =
  | Submit_rejected of access_rejection
  | Submit_admission_blocked of
      { keeper_name : string
      ; reason : Keeper_persistence_admission.block_reason
      }
  | Initial_persistence_failed of { reason : string }
  | Acceptance_persistence_failed of
      { request_id : string
      ; reason : string
      }
  | Background_switch_unavailable of { reason : string }
  | Background_fork_failed of
      { request_id : string
      ; reason : string
      }

type submission_acceptance =
  | Durably_accepted
  | Reconciliation_required of { reason : string }

type submit_outcome =
  { request_id : string
  ; acceptance : submission_acceptance
  }

type persistence_durability =
  | Durably_committed
  | Published_unconfirmed of { reason : string }

type cancel_result =
  | Cancellation_requested of persistence_durability
  | Cancel_not_found
  | Cancel_unreadable of string
  | Cancel_rejected of access_rejection
  | Cancel_worker_ownership_unknown of request_status
  | Cancel_already_terminal of request_status
  | Cancel_persistence_failed of { reason : string }
  | Cancel_worker_signal_failed of
      { durability : persistence_durability
      ; reason : string
      }
  | Cancel_state_invariant_failed of { reason : string }

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
  | Worker_cancelled of
      { cancelled_by : worker_cancel_source
      ; reason : string
      }

type settlement_durability =
  | Durable
  | Volatile_persistence_failure

type settlement_origin =
  | Transition_commit
  | Canonical_reconciliation

type worker_settlement =
  | Status_settlement of
      { status : request_status
      ; durability : settlement_durability
      ; origin : settlement_origin
      }
  | Settlement_projection_error of { poll_result : load_result }

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

module Store_transition_key = struct
  type t =
    { base_path : string
    ; request_id : string
    }

  let equal a b =
    String.equal a.base_path b.base_path
    && String.equal a.request_id b.request_id
  ;;

  let hash key = Hashtbl.hash (key.base_path, key.request_id)
end

module Store_transition_table = Hashtbl.Make (Store_transition_key)

module Keeper_submission_key = struct
  type t =
    { base_path : string
    ; keeper_name : string
    }

  let equal a b =
    String.equal a.base_path b.base_path
    && String.equal a.keeper_name b.keeper_name
  ;;

  let hash key = Hashtbl.hash (key.base_path, key.keeper_name)
end

module Keeper_submission_table = Hashtbl.Make (Keeper_submission_key)

type store_transition_lock =
  { mutex : Eio.Mutex.t
  ; mutable users : int
  }

let mu = Eio.Mutex.create ()
let pending : entry Request_table.t = Request_table.create 16
let transition_locks : Eio.Mutex.t Request_table.t = Request_table.create 16
let active_switches : Eio.Switch.t Request_table.t = Request_table.create 16
let store_transition_locks : store_transition_lock Store_transition_table.t =
  Store_transition_table.create 16
let reserved_request_ids : unit Store_transition_table.t =
  Store_transition_table.create 16
let keeper_submission_locks : store_transition_lock Keeper_submission_table.t =
  Keeper_submission_table.create 16

let durable_write_hook_for_testing :
    (Keeper_fs.durable_write_stage -> unit) option Atomic.t =
  Atomic.make None

let durable_remove_hook_for_testing :
    (Keeper_fs.durable_remove_stage -> unit) option Atomic.t =
  Atomic.make None

let cancel_signal_hook_for_testing :
    (Eio.Switch.t -> exn -> unit) option Atomic.t =
  Atomic.make None

let request_id_hook_for_testing : (unit -> string) option Atomic.t =
  Atomic.make None

let integrity_projection_hook_for_testing : (unit -> unit) option Atomic.t =
  Atomic.make None

let with_store_transition_lock ~base_path ~request_id f =
  let key : Store_transition_key.t = { base_path; request_id } in
  let lock =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      match Store_transition_table.find_opt store_transition_locks key with
      | Some lock ->
        lock.users <- lock.users + 1;
        lock
      | None ->
        let lock = { mutex = Eio.Mutex.create (); users = 1 } in
        Store_transition_table.add store_transition_locks key lock;
        lock)
  in
  (* fun-protect-finally-ok: the registry user-count cleanup acquires only the
     cancellation-protected bookkeeping mutex; it awaits no external event and
     cannot strand the protected exception behind cancellable cleanup. *)
  Fun.protect
    ~finally:(fun () ->
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        lock.users <- lock.users - 1;
        if lock.users = 0
        then
          match Store_transition_table.find_opt store_transition_locks key with
          | Some current when current == lock ->
            Store_transition_table.remove store_transition_locks key
          | Some _ | None -> ()))
    (fun () -> Eio.Mutex.use_rw ~protect:true lock.mutex f)
;;

let with_keeper_submission_lock ~base_path ~keeper_name f =
  let key : Keeper_submission_key.t = { base_path; keeper_name } in
  let lock =
    Eio.Mutex.use_rw ~protect:true mu (fun () ->
      match Keeper_submission_table.find_opt keeper_submission_locks key with
      | Some lock ->
        lock.users <- lock.users + 1;
        lock
      | None ->
        let lock = { mutex = Eio.Mutex.create (); users = 1 } in
        Keeper_submission_table.add keeper_submission_locks key lock;
        lock)
  in
  (* fun-protect-finally-ok: the registry user-count cleanup acquires only the
     cancellation-protected bookkeeping mutex; it awaits no external event and
     cannot strand the protected exception behind cancellable cleanup. *)
  Fun.protect
    ~finally:(fun () ->
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        lock.users <- lock.users - 1;
        if lock.users = 0
        then
          match Keeper_submission_table.find_opt keeper_submission_locks key with
          | Some current when current == lock ->
            Keeper_submission_table.remove keeper_submission_locks key
          | Some _ | None -> ()))
    (fun () -> Eio.Mutex.use_rw ~protect:true lock.mutex f)
;;

exception CancelledByOperator
exception Worker_preempted of string
exception Worker_already_settled of request_status
let record_schema_version = 2

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

let active_request_dir ~base_path = Filename.concat (request_dir ~base_path) "active"
let terminal_request_dir ~base_path = Filename.concat (request_dir ~base_path) "terminal"

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

let record_path_in directory ~request_id =
  if is_safe_request_id request_id
  then Some (Filename.concat directory (request_id ^ ".json"))
  else None
;;

let active_record_path ~base_path ~request_id =
  record_path_in (active_request_dir ~base_path) ~request_id
;;

let terminal_record_path ~base_path ~request_id =
  record_path_in (terminal_request_dir ~base_path) ~request_id
;;

let legacy_record_path ~base_path ~request_id =
  record_path_in (request_dir ~base_path) ~request_id
;;

let status_to_string = function
  | Queued -> "queued"
  | Running -> "running"
  | Cancelling _ -> "cancelling"
  | Lost _ -> "lost"
  | Cancelled _ -> "cancelled"
  | Persistence_failed _ -> "persistence_failed"
  | Done { ok = true; _ } -> "done"
  | Done { ok = false; _ } -> "error"
;;

let is_terminal_status = function
  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ -> true
  | Queued | Running | Cancelling _ -> false
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
  | Submit_admission_blocked { keeper_name; reason } ->
    let message =
      match reason with
      | Keeper_persistence_admission.Recovery_failed ->
        "The Keeper lane is fenced because durable queue or delivery recovery failed; repair the typed recovery error and restart before dispatch."
      | Keeper_persistence_admission.Reconciliation_required ->
        "The Keeper lane is fenced because a prior request acceptance requires canonical persistence reconciliation; inspect its preserved request id and repair before restart."
    in
    `Assoc
      [ "error", `String "keeper_persistence_admission_blocked"
      ; "keeper_name", `String keeper_name
      ; "reason", `String (Keeper_persistence_admission.block_reason_to_wire reason)
      ; "message", `String message
      ]
  | Initial_persistence_failed { reason } ->
    `Assoc
      [ "error", `String "request_persistence_failed"
      ; "message", `String reason
      ]
  | Acceptance_persistence_failed { request_id; reason } ->
    `Assoc
      [ "error", `String "acceptance_persistence_failed"
      ; "request_id", `String request_id
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

let submit_outcome_to_json outcome =
  match outcome.acceptance with
  | Durably_accepted ->
    `Assoc
      [ "request_id", `String outcome.request_id
      ; "status", `String "queued"
      ; "durability", `String "durable"
      ]
  | Reconciliation_required { reason } ->
    `Assoc
      [ "error", `String "request_acceptance_uncertain"
      ; "request_id", `String outcome.request_id
      ; "status", `String "acceptance_uncertain"
      ; "reconciliation_required", `Bool true
      ; "reason", `String reason
      ]
;;

let durability_json_fields = function
  | Durably_committed -> [ "durability", `String "durable" ]
  | Published_unconfirmed { reason } ->
    [ "durability", `String "volatile"; "warning", `String reason ]
;;

let cancel_result_to_json ~request_id = function
  | Cancellation_requested durability ->
    `Assoc
      ([ "request_id", `String request_id
       ; "status", `String "cancelling"
       ; ( "message"
         , `String
             "Keeper cancellation was accepted; poll the request for its actual terminal result."
         )
       ]
       @ durability_json_fields durability)
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
  | Cancel_worker_ownership_unknown status ->
    `Assoc
      [ "error", `String "request_worker_ownership_unknown"
      ; "request_id", `String request_id
      ; "status", `String (status_to_string status)
      ; ( "message"
        , `String
            "The request is non-terminal on disk but has no worker in this process; cancellation is refused because another runtime may own it."
        )
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
  | Cancel_worker_signal_failed { durability; reason } ->
    `Assoc
      ([ "error", `String "cancellation_worker_signal_failed"
       ; "request_id", `String request_id
       ; "status", `String "cancelling"
       ; "message", `String reason
       ]
       @ durability_json_fields durability)
  | Cancel_state_invariant_failed { reason } ->
    `Assoc
      [ "error", `String "cancellation_state_invariant_failed"
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
    | Cancelling { reason; cancelled_by } ->
      fields @ [ "reason", `String reason; "cancelled_by", `String cancelled_by ]
    | Persistence_failed { attempted_status; reason } ->
      fields
      @ [ "attempted_status", `String attempted_status; "reason", `String reason ]
    | Queued | Running -> fields
  in
  `Assoc fields
;;

let same_request_identity (left : entry) (right : entry) =
  String.equal left.request_id right.request_id
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.base_path right.base_path
  && String.equal left.submitted_by right.submitted_by
  && Float.equal left.submitted_at right.submitted_at
;;

type source_comparison =
  | Exact_source_duplicate
  | Conflicting_source_identity
  | Conflicting_source_state

let compare_source_entries left right =
  if not (same_request_identity left right)
  then Conflicting_source_identity
  else if entry_record_to_json left = entry_record_to_json right
  then Exact_source_duplicate
  else Conflicting_source_state
;;

let source_conflict_to_string = function
  | Exact_source_duplicate -> "active and legacy request records are exact duplicates"
  | Conflicting_source_identity ->
    "conflicting request identities coexist across active and legacy partitions"
  | Conflicting_source_state ->
    "conflicting request states coexist across active and legacy partitions"
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
  | "cancelling" ->
    let* reason = required_string "reason" json in
    let* cancelled_by = required_string "cancelled_by" json in
    Ok (Cancelling { reason; cancelled_by }, None)
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
    | Cancelling _ -> [ "reason"; "cancelled_by" ]
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

let load_record_at_path ~base_path ~request_id path =
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
    Unreadable reason
;;

type record_location =
  | Terminal_location
  | Active_location
  | Legacy_location

type located_load_result =
  | Located of entry * record_location * string
  | Located_absent
  | Located_unreadable of string
  | Located_rejected of access_rejection

let observe_namespace_degradation ~operation (entry : entry) detail =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string FsFailures)
    ~labels:[ "subsystem", "keeper_msg_async"; "operation", operation ]
    ();
  Log.Keeper.warn
    "keeper_msg_async: namespace durability degraded operation=%s request_id=%s path_identity=%s detail=%s"
    operation
    entry.request_id
    entry.base_path
    detail
;;

let remove_duplicate_source ~(entry : entry) path =
  let result =
    match Atomic.get durable_remove_hook_for_testing with
    | None -> Keeper_fs.remove_file_durable path
    | Some before_stage ->
      Keeper_fs.For_testing.remove_file_durable ~before_stage path
  in
  match result with
  | Ok () -> true
  | Error error ->
    observe_namespace_degradation
      ~operation:"terminal_source_cleanup"
      entry
      (Printf.sprintf
         "removed=%b %s"
         error.removed
         (Keeper_fs.durable_remove_error_to_string error));
    error.removed
;;

type persist_integrity_error =
  | Unsafe_request_id
  | Terminal_partition_nonterminal
  | Terminal_conflict
  | Terminal_unreadable of string
  | Terminal_disappeared
  | Terminal_access_rejected of access_rejection

type write_failure =
  | Not_published of Keeper_fs.durable_write_error
  | Published_uncertain of Keeper_fs.durable_write_error

type persist_error =
  | Write_failed of write_failure
  | Integrity_failed of persist_integrity_error

let persist_integrity_error_to_string = function
  | Unsafe_request_id -> "request_id is unsafe for persistence"
  | Terminal_partition_nonterminal ->
    "terminal partition contains a non-terminal request record"
  | Terminal_conflict ->
    "terminal request record conflicts with the transition candidate"
  | Terminal_unreadable reason ->
    Printf.sprintf "terminal request record is unreadable: %s" reason
  | Terminal_disappeared ->
    "terminal request record disappeared during transition"
  | Terminal_access_rejected rejection ->
    access_rejection_to_json rejection |> Yojson.Safe.to_string
;;

let persist_error_to_string = function
  | Write_failed (Not_published error | Published_uncertain error) ->
    Keeper_fs.durable_write_error_to_string error
  | Integrity_failed error -> persist_integrity_error_to_string error
;;

let persist_error_published = function
  | Write_failed (Not_published _) -> false
  | Write_failed (Published_uncertain _) -> true
  | Integrity_failed _ -> false
;;

let save_entry_durable path (entry : entry) =
  (match Atomic.get durable_write_hook_for_testing with
   | None -> Keeper_fs.save_json_durable_atomic path (entry_record_to_json entry)
   | Some before_stage ->
     Keeper_fs.For_testing.save_json_durable_atomic
       ~before_stage
       path
       (entry_record_to_json entry))
  |> Result.map_error (fun error ->
    Write_failed
      (if error.Keeper_fs.renamed
       then Published_uncertain error
       else Not_published error))
;;

let persist_terminal_from_source ~(entry : entry) ~source_path =
  match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Error (Integrity_failed Unsafe_request_id)
  | Some terminal_path ->
    if String.equal source_path terminal_path
    then save_entry_durable source_path entry
    else if Fs_compat.file_exists terminal_path
    then (
      match
        load_record_at_path
          ~base_path:entry.base_path
          ~request_id:entry.request_id
          terminal_path
      with
      | Found terminal_entry when not (is_terminal_status terminal_entry.status) ->
        Error (Integrity_failed Terminal_partition_nonterminal)
      | Found terminal_entry ->
        if entry_record_to_json terminal_entry = entry_record_to_json entry
        then (
          (* See lossless namespace protocol: observed cleanup failure is retried. *)
          ignore (remove_duplicate_source ~entry source_path : bool);
          Ok ())
        else
          Error (Integrity_failed Terminal_conflict)
      | Unreadable reason ->
        Error (Integrity_failed (Terminal_unreadable reason))
      | Absent ->
        Error (Integrity_failed Terminal_disappeared)
      | Rejected rejection ->
        Error (Integrity_failed (Terminal_access_rejected rejection))
    )
    else (
      (* Lossless namespace protocol: first durably publish the terminal
         destination, then durably remove the active/legacy source. A crash
         before destination commit leaves the source authoritative; a crash
         after destination commit may leave both names, and exact lookup gives
         terminal precedence. Never rename the sole source across directories:
         partial parent-directory fsync can otherwise lose both names. *)
      let* () = save_entry_durable terminal_path entry in
      (* See lossless namespace protocol: observed cleanup failure is retried. *)
      ignore (remove_duplicate_source ~entry source_path : bool);
      Ok ())
;;

let persist_entry ?source_path (entry : entry) =
  match active_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Error (Integrity_failed Unsafe_request_id)
  | Some active_path ->
    if is_terminal_status entry.status
    then
      persist_terminal_from_source
        ~entry
        ~source_path:(Option.value source_path ~default:active_path)
    else save_entry_durable active_path entry
;;

let load_record_canonical_located ~base_path ~request_id : located_load_result =
  match
    terminal_record_path ~base_path ~request_id,
    active_record_path ~base_path ~request_id,
    legacy_record_path ~base_path ~request_id
  with
  | None, _, _ | _, None, _ | _, _, None -> Located_rejected Invalid_request_id
  | Some terminal_path, Some active_path, Some legacy_path ->
    let validate_terminal_sources terminal_entry =
      let rec loop = function
        | [] -> Located (terminal_entry, Terminal_location, terminal_path)
        | path :: rest ->
          if not (Fs_compat.file_exists path)
          then loop rest
          else (
            match load_record_at_path ~base_path ~request_id path with
            | Found source_entry ->
              if not (same_request_identity source_entry terminal_entry)
              then
                Located_unreadable
                  "conflicting request identities coexist across persistence partitions"
              else if
                is_terminal_status source_entry.status
                && entry_record_to_json source_entry
                   <> entry_record_to_json terminal_entry
              then
                Located_unreadable
                  "conflicting terminal request records coexist across persistence partitions"
              else loop rest
            | Unreadable reason ->
              Located_unreadable
                (Printf.sprintf
                   "terminal request record coexists with an unreadable source record: %s"
                   reason)
            | Rejected rejection -> Located_rejected rejection
            | Absent -> loop rest)
      in
      loop [ active_path; legacy_path ]
    in
    let validate_active_source active_entry =
      if not (Fs_compat.file_exists legacy_path)
      then Located (active_entry, Active_location, active_path)
      else
        match load_record_at_path ~base_path ~request_id legacy_path with
        | Found legacy_entry ->
          (match compare_source_entries active_entry legacy_entry with
           | Exact_source_duplicate ->
             Located (active_entry, Active_location, active_path)
           | (Conflicting_source_identity | Conflicting_source_state) as conflict ->
             Located_unreadable
               (source_conflict_to_string conflict))
        | Unreadable reason ->
          Located_unreadable
            (Printf.sprintf
               "active request record coexists with an unreadable legacy record: %s"
               reason)
        | Rejected rejection -> Located_rejected rejection
        | Absent -> Located (active_entry, Active_location, active_path)
    in
    let rec first_existing = function
      | [] -> Located_absent
      | (location, path) :: rest ->
        if Fs_compat.file_exists path
        then (
          match load_record_at_path ~base_path ~request_id path with
          | Found entry ->
            if location = Terminal_location && not (is_terminal_status entry.status)
            then
              Located_unreadable
                "terminal partition contains a non-terminal request record"
            else if location = Terminal_location
            then validate_terminal_sources entry
            else if location = Active_location
            then validate_active_source entry
            else Located (entry, location, path)
          | Unreadable reason -> Located_unreadable reason
          | Rejected rejection -> Located_rejected rejection
          | Absent -> first_existing rest)
        else first_existing rest
    in
    first_existing
      [ Terminal_location, terminal_path
      ; Active_location, active_path
      ; Legacy_location, legacy_path
      ]
;;

let load_record_canonical ~base_path ~request_id : load_result =
  match load_record_canonical_located ~base_path ~request_id with
  | Located (entry, _, _) -> Found entry
  | Located_absent -> Absent
  | Located_unreadable reason -> Unreadable reason
  | Located_rejected rejection -> Rejected rejection
;;

let load_record ~base_path ~request_id : load_result =
  match canonical_base_path base_path with
  | Error rejection -> Rejected rejection
  | Ok base_path -> load_record_canonical ~base_path ~request_id
;;

let observe_persist_error ~operation (entry : entry) = function
  | Ok () -> Ok ()
  | Error error ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string FsFailures)
      ~labels:[ "subsystem", "keeper_msg_async"; "operation", operation ]
      ();
    let published = persist_error_published error in
    let reason = persist_error_to_string error in
    Log.Keeper.error
      "keeper_msg_async: %s persist failed request_id=%s path_identity=%s published=%b error=%s"
      operation
      entry.request_id
      entry.base_path
      published
      reason;
    Error error
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

let rollback_rejected_record_file path =
  let result =
    match Atomic.get durable_remove_hook_for_testing with
    | None -> Keeper_fs.remove_file_durable path
    | Some before_stage ->
      Keeper_fs.For_testing.remove_file_durable ~before_stage path
  in
  match result with
  | Ok () -> Ok ()
  | Error error ->
    Log.Keeper.error
      "keeper_msg_async: rejected-record rollback failed path=%s removed=%b error=%s"
      path
      error.removed
      (Keeper_fs.durable_remove_error_to_string error);
    Error error
;;

let mark_lost_after_recovery ?source_path (entry : entry) =
  let reason =
    "keeper_msg request was accepted but no live worker owns it; the server may have \
     restarted or evicted the request before terminal result"
  in
  let lost =
    { entry with status = Lost { reason }; completed_at = Some (Time_compat.now ()) }
  in
  match
    persist_entry ?source_path lost
    |> observe_persist_error ~operation:"recovery" lost
  with
  | Ok () -> Ok lost
  | Error error -> Error (persist_error_to_string error)
;;

let request_has_live_worker ~base_path ~submitted_by request_id =
  let key = request_key ~base_path ~submitted_by ~request_id in
  Eio.Mutex.use_ro mu (fun () -> Request_table.mem pending key)
;;

let recovery_terminal_operation = function
  | Active_store -> "active_terminal_finalize"
  | Legacy_store -> "legacy_terminal_finalize"
;;

type terminal_destination_state =
  | No_terminal_destination
  | Cleanup_source
  | Invalid_terminal_destination of persist_integrity_error

type recovery_source_state =
  | Recovery_source_ready
  | Recovery_duplicate_waiting_for_active
  | Recovery_source_conflict of string

let recovery_source_state ~source (entry : entry) =
  match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Recovery_source_conflict "request_id is unsafe for persistence"
  | Some terminal_path when Fs_compat.file_exists terminal_path ->
    Recovery_source_ready
  | Some _ ->
    let peer_path =
      match source with
      | Active_store ->
        legacy_record_path ~base_path:entry.base_path ~request_id:entry.request_id
      | Legacy_store ->
        active_record_path ~base_path:entry.base_path ~request_id:entry.request_id
    in
    (match peer_path with
     | None -> Recovery_source_conflict "request_id is unsafe for persistence"
     | Some peer_path when not (Fs_compat.file_exists peer_path) ->
       Recovery_source_ready
     | Some peer_path ->
       (match
          load_record_at_path
            ~base_path:entry.base_path
            ~request_id:entry.request_id
            peer_path
        with
        | Found peer_entry ->
          (match compare_source_entries entry peer_entry with
           | Exact_source_duplicate ->
             (match source with
              | Active_store -> Recovery_source_ready
              | Legacy_store -> Recovery_duplicate_waiting_for_active)
           | (Conflicting_source_identity | Conflicting_source_state) as conflict ->
             Recovery_source_conflict (source_conflict_to_string conflict))
        | Unreadable reason ->
          Recovery_source_conflict
            (Printf.sprintf "coexisting request source is unreadable: %s" reason)
        | Rejected rejection ->
          Recovery_source_conflict
            (Printf.sprintf
               "coexisting request source was rejected: %s"
               (access_rejection_to_json rejection |> Yojson.Safe.to_string))
        | Absent -> Recovery_source_ready))
;;

let terminal_destination_state (entry : entry) =
  match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Invalid_terminal_destination Unsafe_request_id
  | Some terminal_path ->
    if not (Fs_compat.file_exists terminal_path)
    then No_terminal_destination
    else (
      match
        load_record_at_path
          ~base_path:entry.base_path
          ~request_id:entry.request_id
          terminal_path
      with
      | Found terminal_entry when is_terminal_status terminal_entry.status ->
        if not (same_request_identity entry terminal_entry)
        then Invalid_terminal_destination Terminal_conflict
        else if
          (not (is_terminal_status entry.status))
          || entry_record_to_json terminal_entry = entry_record_to_json entry
        then Cleanup_source
        else
          Invalid_terminal_destination Terminal_conflict
      | Found _ ->
        Invalid_terminal_destination Terminal_partition_nonterminal
      | Unreadable reason ->
        Invalid_terminal_destination (Terminal_unreadable reason)
      | Absent -> Invalid_terminal_destination Terminal_disappeared
      | Rejected rejection ->
        Invalid_terminal_destination (Terminal_access_rejected rejection))
;;

let finalize_existing_terminal_source ~(entry : entry) source_path =
  match terminal_record_path ~base_path:entry.base_path ~request_id:entry.request_id with
  | None -> Error (Integrity_failed Unsafe_request_id)
  | Some terminal_path ->
    let* () = save_entry_durable terminal_path entry in
    Ok (remove_duplicate_source ~entry source_path)
;;

let empty_recovery_report =
  { lost = 0
  ; migrated = 0
  ; cleaned = 0
  ; deferred = 0
  ; unreadable = 0
  ; failed = 0
  ; store_errors = []
  ; record_errors = []
  }
;;

module Keeper_name_set = Set.Make (String)

let recovery_record_error_kind_to_string = function
  | Recovery_record_unreadable reason -> "unreadable: " ^ reason
  | Recovery_record_missing -> "record disappeared during recovery"
  | Recovery_record_not_file -> "record path is not a regular file"
  | Recovery_record_rejected rejection ->
    "record identity rejected: "
    ^ (access_rejection_to_json rejection |> Yojson.Safe.to_string)
  | Recovery_source_ambiguity reason -> "source ambiguity: " ^ reason
  | Recovery_terminal_integrity reason -> "terminal integrity: " ^ reason
  | Recovery_persistence_failed reason -> "persistence failed: " ^ reason
  | Recovery_source_cleanup_failed -> "source cleanup failed"
  | Recovery_entry_exception reason -> "entry exception: " ^ reason
;;

let record_error ~store ~path ~request_id ?keeper_name kind report =
  Log.Keeper.error
    "keeper_msg_async: recovery record failed store=%s request_id=%s keeper=%s path=%s error=%s"
    (match store with
     | Active_store -> "active"
     | Legacy_store -> "legacy")
    request_id
    (Option.value keeper_name ~default:"<unattributed>")
    path
    (recovery_record_error_kind_to_string kind);
  { report with
    record_errors =
      { store; path; request_id; keeper_name; kind } :: report.record_errors
  }
;;

let recover_record_path ~base_path ~source ~blocked_keeper_names ~request_id path report =
  match load_record_at_path ~base_path ~request_id path with
  | Found entry ->
    (match recovery_source_state ~source entry with
     | Recovery_source_conflict reason ->
       { (record_error
            ~store:source
            ~path
            ~request_id
            ~keeper_name:entry.keeper_name
            (Recovery_source_ambiguity reason)
            report) with
         failed = report.failed + 1
       }
     | Recovery_duplicate_waiting_for_active ->
       (* Active is the canonical source. Do not remove or terminalize the
          legacy duplicate until the active transition has durably published
          its destination. The normal active-first sweep reaches that state
          before scanning legacy; this branch preserves evidence if a caller
          presents the stores in another order or the active lane is fenced. *)
       { report with deferred = report.deferred + 1 }
     | Recovery_source_ready ->
       (match terminal_destination_state entry with
     | Cleanup_source ->
       if remove_duplicate_source ~entry path
       then { report with cleaned = report.cleaned + 1 }
       else
         { (record_error
              ~store:source
              ~path
              ~request_id
              ~keeper_name:entry.keeper_name
              Recovery_source_cleanup_failed
              report) with
           failed = report.failed + 1
         }
     | Invalid_terminal_destination integrity_error ->
       ignore
         (observe_persist_error
            ~operation:"recovery_terminal_conflict"
            entry
           (Error (Integrity_failed integrity_error))
           : (unit, persist_error) result);
       { (record_error
            ~store:source
            ~path
            ~request_id
            ~keeper_name:entry.keeper_name
            (Recovery_terminal_integrity
               (persist_integrity_error_to_string integrity_error))
            report) with
         failed = report.failed + 1
       }
     | No_terminal_destination ->
       if is_terminal_status entry.status
       then (
         match
           finalize_existing_terminal_source ~entry path
         with
         | Ok true -> { report with migrated = report.migrated + 1 }
         | Ok false ->
           { (record_error
                ~store:source
                ~path
                ~request_id
                ~keeper_name:entry.keeper_name
                Recovery_source_cleanup_failed
                report) with
             failed = report.failed + 1
           }
         | Error error ->
           ignore
             (observe_persist_error
                ~operation:(recovery_terminal_operation source)
                entry
                (Error error)
               : (unit, persist_error) result);
           { (record_error
                ~store:source
                ~path
                ~request_id
                ~keeper_name:entry.keeper_name
                (Recovery_persistence_failed (persist_error_to_string error))
                report) with
             failed = report.failed + 1
           })
       else if
         request_has_live_worker
           ~base_path
           ~submitted_by:entry.submitted_by
           request_id
       then report
       else if Keeper_name_set.mem entry.keeper_name blocked_keeper_names
       then { report with deferred = report.deferred + 1 }
       else (
         match mark_lost_after_recovery ~source_path:path entry with
         | Ok _ -> { report with lost = report.lost + 1 }
         | Error reason ->
           { (record_error
                ~store:source
                ~path
                ~request_id
                ~keeper_name:entry.keeper_name
                (Recovery_persistence_failed reason)
                report) with
             failed = report.failed + 1
           })))
  | Unreadable reason ->
    { (record_error
         ~store:source
         ~path
         ~request_id
         (Recovery_record_unreadable reason)
         report) with
      unreadable = report.unreadable + 1
    }
  | Absent ->
    { (record_error
         ~store:source
         ~path
         ~request_id
         Recovery_record_missing
         report) with
      failed = report.failed + 1
    }
  | Rejected rejection ->
    { (record_error
         ~store:source
         ~path
         ~request_id
         (Recovery_record_rejected rejection)
         report) with
      failed = report.failed + 1
    }
;;

let store_error ~store ~path reason report =
  { report with
    failed = report.failed + 1
  ; store_errors = { store; path; reason } :: report.store_errors
  }
;;

let recover_record_directory ~base_path ~source ~blocked_keeper_names dir report =
  try
    match Fs_compat.path_kind dir with
    | Fs_compat.Missing -> report
    | Fs_compat.Other ->
      store_error
        ~store:source
        ~path:dir
        "keeper_msg request store path is not a directory"
        report
    | Fs_compat.Directory ->
      Fs_compat.read_dir dir
      |> List.fold_left
           (fun report name ->
              Eio_guard.fair_yield ();
              match request_id_of_record_filename name with
              | None -> report
              | Some request_id ->
                let path = Filename.concat dir name in
                (try
                   match Fs_compat.path_kind path with
                   | Fs_compat.Directory ->
                     { (record_error
                          ~store:source
                          ~path
                          ~request_id
                          Recovery_record_not_file
                          report) with
                       failed = report.failed + 1
                     }
                   | Fs_compat.Missing ->
                     { (record_error
                          ~store:source
                          ~path
                          ~request_id
                          Recovery_record_missing
                          report) with
                       failed = report.failed + 1
                     }
                   | Fs_compat.Other ->
                     with_store_transition_lock
                       ~base_path
                       ~request_id
                       (fun () ->
                          recover_record_path
                            ~base_path
                            ~source
                            ~blocked_keeper_names
                            ~request_id
                            path
                            report)
                 with
                 | Eio.Cancel.Cancelled _ as exn -> raise exn
                 | exn ->
                   Log.Keeper.error
                     "keeper_msg_async: recovery entry failed request_id=%s path=%s error=%s"
                     request_id
                     path
                     (Printexc.to_string exn);
                   { (record_error
                        ~store:source
                        ~path
                        ~request_id
                        (Recovery_entry_exception (Printexc.to_string exn))
                        report) with
                     failed = report.failed + 1
                   }))
           report
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error
      "keeper_msg_async: recovery directory failed dir=%s error=%s"
      dir
      (Printexc.to_string exn);
    store_error ~store:source ~path:dir (Printexc.to_string exn) report
;;

let recover_lost_disk_records_canonical ~base_path ~blocked_keeper_names =
  let blocked_keeper_names = Keeper_name_set.of_list blocked_keeper_names in
  let active_dir = active_request_dir ~base_path in
  let legacy_dir = request_dir ~base_path in
  let report =
    recover_record_directory
    ~base_path
    ~source:Active_store
    ~blocked_keeper_names
    active_dir
    empty_recovery_report
      |> recover_record_directory
           ~base_path
           ~source:Legacy_store
           ~blocked_keeper_names
           legacy_dir
  in
  { report with
    store_errors = List.rev report.store_errors
  ; record_errors = List.rev report.record_errors
  }
;;

let recover_lost_disk_records ?(blocked_keeper_names = []) ~base_path () =
  match canonical_base_path base_path with
  | Ok base_path ->
    recover_lost_disk_records_canonical ~base_path ~blocked_keeper_names
  | Error rejection ->
    Log.Keeper.error
      "keeper_msg_async: recovery rejected base_path error=%s"
      (Yojson.Safe.to_string (access_rejection_to_json rejection));
    { empty_recovery_report with failed = 1 }
;;

let generate_request_id () =
  match Atomic.get request_id_hook_for_testing with
  | None -> Random_id.prefixed ~prefix:"kmsg-" ~bytes:16
  | Some generate -> generate ()
;;

let with_lock f = Eio.Mutex.use_rw ~protect:true mu (fun () -> f ())

let reserve_new_request ~base_path ~submitted_by ~keeper_name =
  let rec reserve () =
    let request_id = generate_request_id () in
    if not (is_safe_request_id request_id)
    then reserve ()
    else
      match
        with_store_transition_lock ~base_path ~request_id (fun () ->
          match load_record_canonical_located ~base_path ~request_id with
          | Located_absent ->
            with_lock (fun () ->
              let reservation_key : Store_transition_key.t =
                { base_path; request_id }
              in
              if Store_transition_table.mem reserved_request_ids reservation_key
              then None
              else
                let entry =
                  { request_id
                  ; keeper_name
                  ; base_path
                  ; submitted_by
                  ; status = Queued
                  ; submitted_at = Time_compat.now ()
                  ; completed_at = None
                  }
                in
                let key = request_key ~base_path ~submitted_by ~request_id in
                let transition_lock = Eio.Mutex.create () in
                Store_transition_table.add
                  reserved_request_ids
                  reservation_key
                  ();
                Request_table.add pending key entry;
                Request_table.add transition_locks key transition_lock;
                Some (request_id, entry, key, transition_lock))
          | Located _ | Located_unreadable _ | Located_rejected _ -> None)
      with
      | Some reserved -> reserved
      | None -> reserve ()
  in
  reserve ()
;;

let remove_runtime_tables_if_owned ~release_reservation key transition_lock =
  with_lock (fun () ->
    match Request_table.find_opt transition_locks key with
    | Some current when current == transition_lock ->
      if release_reservation
      then
        Store_transition_table.remove
          reserved_request_ids
          ({ base_path = key.base_path; request_id = key.request_id }
            : Store_transition_key.t);
      Request_table.remove pending key;
      Request_table.remove transition_locks key
    | Some _ | None -> ())
;;

let remove_runtime_if_owned =
  remove_runtime_tables_if_owned ~release_reservation:true
;;

let detach_runtime_preserving_reservation_if_owned =
  remove_runtime_tables_if_owned ~release_reservation:false
;;

let publish_if_owned key transition_lock entry =
  with_lock (fun () ->
    match Request_table.find_opt transition_locks key with
    | Some current when current == transition_lock ->
      Request_table.replace pending key entry
    | Some _ | None -> ())
;;

let project_canonical_integrity_failure_locked key transition_lock
    (attempted_entry : entry) =
  (* An integrity error means another durable record is already authoritative
     or the namespace cannot be trusted. Do not attempt a competing marker
     write and do not shadow it with process-local polling truth. The closed
     projection carries exact canonical lookup truth, including an explicit
     load error when no terminal [request_status] can represent it. *)
  Option.iter (fun hook -> hook ()) (Atomic.get integrity_projection_hook_for_testing);
  let poll_result =
    load_record_canonical
      ~base_path:attempted_entry.base_path
      ~request_id:attempted_entry.request_id
  in
  (match poll_result with
   | Absent ->
     (* Publish the lane fence before detaching volatile ownership. A submit
        that has not yet crossed its per-Keeper admission check then fails
        before allocating another request id; at most the one submit already
        inside that lane's acceptance critical section can precede the fence. *)
     Keeper_persistence_admission.block_reconciliation_required
       ~base_path:attempted_entry.base_path
       ~keeper_name:attempted_entry.keeper_name;
     detach_runtime_preserving_reservation_if_owned key transition_lock
   | Found _ | Unreadable _ | Rejected _ ->
     remove_runtime_if_owned key transition_lock);
  match poll_result with
  | Found canonical when is_terminal_status canonical.status ->
    Status_settlement
      { status = canonical.status
      ; durability = Durable
      ; origin = Canonical_reconciliation
      }
  | poll_result -> Settlement_projection_error { poll_result }
;;

let persist_failure_locked key transition_lock (attempted_entry : entry) reason =
  let failure_entry =
    { attempted_entry with
      status =
        Persistence_failed
          { attempted_status = status_to_string attempted_entry.status; reason }
    ; completed_at = Some (Time_compat.now ())
    }
  in
  match
    persist_entry failure_entry
    |> observe_persist_error ~operation:"persistence_failure_marker" failure_entry
  with
  | Ok () ->
    remove_runtime_if_owned key transition_lock;
    Status_settlement
      { status = failure_entry.status
      ; durability = Durable
      ; origin = Transition_commit
      }
  | Error (Write_failed (Published_uncertain _)) ->
    publish_if_owned key transition_lock failure_entry;
    Status_settlement
      { status = failure_entry.status
      ; durability = Volatile_persistence_failure
      ; origin = Transition_commit
      }
  | Error (Write_failed (Not_published _)) ->
    (* The durable row still contains the previous non-terminal status. Keep
       an explicit volatile terminal overlay in this process so polling cannot
       hang indefinitely; restart recovery later converts the stale durable
       row to typed [Lost]. *)
    publish_if_owned key transition_lock failure_entry;
    Status_settlement
      { status = failure_entry.status
      ; durability = Volatile_persistence_failure
      ; origin = Transition_commit
      }
  | Error (Integrity_failed _) ->
    project_canonical_integrity_failure_locked key transition_lock failure_entry
;;

let transition_lock_for_key key =
  with_lock (fun () -> Request_table.find_opt transition_locks key)
;;

let set_status ?(preserve_terminal = false) key status =
  match transition_lock_for_key key with
  | None -> None
  | Some transition_lock ->
    Eio.Mutex.use_rw ~protect:true transition_lock (fun () ->
      let current =
        with_lock (fun () ->
          match
            Request_table.find_opt transition_locks key,
            Request_table.find_opt pending key
          with
          | Some owned, Some entry when owned == transition_lock -> Some entry
          | _ -> None)
      in
      match current with
      | None -> None
      | Some entry when preserve_terminal && is_terminal_status entry.status -> None
      | Some { status = Cancelling _; _ } when status = Running -> None
      | Some entry ->
        let completed_at =
          match status with
          | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
            (* NDT-OK: completed_at is observational wall-clock metadata for
               terminal request records; state transitions are status-derived. *)
            Some (Time_compat.now ())
          | Queued | Running | Cancelling _ -> None
        in
        let updated = { entry with status; completed_at } in
        (match
           persist_entry updated
           |> observe_persist_error ~operation:"status_update" updated
         with
         | Ok () ->
           if is_terminal_status updated.status
           then remove_runtime_if_owned key transition_lock
           else publish_if_owned key transition_lock updated;
           Some
             (Status_settlement
                { status = updated.status
                ; durability = Durable
                ; origin = Transition_commit
                })
         | Error (Write_failed (Published_uncertain _)) ->
           (* The new bytes are visible but their parent-directory fsync did
              not commit. Keep the typed attempted state in memory so exact
              poll cannot disagree with the currently published file, and
              report volatile durability to every live projection. *)
           publish_if_owned key transition_lock updated;
           Some
             (Status_settlement
                { status = updated.status
                ; durability = Volatile_persistence_failure
                ; origin = Transition_commit
                })
         | Error (Write_failed (Not_published error)) ->
           Some
             (persist_failure_locked
                key
                transition_lock
                updated
                (Keeper_fs.durable_write_error_to_string error))
         | Error (Integrity_failed _) ->
           Some
             (project_canonical_integrity_failure_locked
                key
                transition_lock
                updated)))
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

let operator_cancel_reason = "keeper_msg request was cancelled by operator"

let operator_cancelling_status () =
  Cancelling
    { reason = operator_cancel_reason
    ; cancelled_by = worker_cancel_source_to_string Operator_request
    }
;;

let operator_cancelled_status () =
  cancelled_status
    ~cancelled_by:(worker_cancel_source_to_string Operator_request)
    operator_cancel_reason
;;

let runtime_cancelled_status () =
  cancelled_status
    ~cancelled_by:"runtime"
    "keeper_msg worker was cancelled by runtime before terminal result"
;;

let submit ?on_accepted ?on_worker_aborted ?on_worker_settled ~background_sw
    ~base_path ~caller ~(f : Eio.Switch.t -> tool_result) ~keeper_name () :
    (submit_outcome, submit_error) result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Error (Submit_rejected rejection)
  | Ok (base_path, submitted_by) ->
    with_keeper_submission_lock ~base_path ~keeper_name (fun () ->
    (match Keeper_persistence_admission.block_reason ~base_path ~keeper_name with
     | Some reason -> Error (Submit_admission_blocked { keeper_name; reason })
     | None ->
    let request_id, entry, key, transition_lock =
      reserve_new_request ~base_path ~submitted_by ~keeper_name
    in
    let reconciliation_outcome reason =
      Keeper_persistence_admission.block_reconciliation_required
        ~base_path
        ~keeper_name;
      Ok
        { request_id
        ; acceptance = Reconciliation_required { reason }
        }
    in
    (match persist_entry entry |> observe_persist_error ~operation:"initial" entry with
     | Error error ->
       let reason = persist_error_to_string error in
       (match error with
        | Write_failed (Published_uncertain _) ->
          (match active_record_path ~base_path ~request_id with
           | None ->
             detach_runtime_preserving_reservation_if_owned key transition_lock;
             reconciliation_outcome
               (Printf.sprintf
                  "%s; published request path could not be reconstructed for durable rollback"
                  reason)
           | Some path ->
             (match rollback_rejected_record_file path with
              | Ok () ->
                remove_runtime_if_owned key transition_lock;
                Error (Initial_persistence_failed { reason })
              | Error rollback_error ->
                detach_runtime_preserving_reservation_if_owned key transition_lock;
                reconciliation_outcome
                  (Printf.sprintf
                     "%s; rollback=%s"
                     reason
                     (Keeper_fs.durable_remove_error_to_string rollback_error))))
        | Write_failed (Not_published _) | Integrity_failed _ ->
          remove_runtime_if_owned key transition_lock;
          Error (Initial_persistence_failed { reason }))
     | Ok () ->
       let acceptance_result =
         match on_accepted with
         | None -> Ok ()
         | Some callback ->
           Eio.Cancel.protect (fun () ->
             match callback request_id with
             | Ok () -> Ok ()
             | Error _ as error -> error
             | exception exn -> Error (Printexc.to_string exn))
       in
       (match acceptance_result with
        | Error reason ->
          ignore
            (set_status_protected
               key
               (Persistence_failed
                  { attempted_status = "accepted"; reason })
             : worker_settlement option);
          Error (Acceptance_persistence_failed { request_id; reason })
        | Ok () ->
          let notify_aborted reason =
            match on_worker_aborted with
            | None -> Ok ()
            | Some callback ->
              Eio.Cancel.protect (fun () ->
                match callback reason with
                | Ok () -> Ok ()
                | Error detail -> Error detail
                | exception exn ->
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string LifecycleCallbackFailures)
                    ~labels:[ "callback", "keeper_msg_async_on_worker_aborted" ]
                    ();
                  Log.Keeper.error
                    "keeper_msg_async: on_worker_aborted callback failed request_id=%s error=%s"
                    request_id
                    (Printexc.to_string exn);
                  Error (Printexc.to_string exn))
          in
          let notify_settled settlement =
            match on_worker_settled with
            | None -> ()
            | Some callback ->
              Eio.Cancel.protect (fun () ->
                try callback settlement with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn ->
                  Otel_metric_store.inc_counter
                    Keeper_metrics.(to_string LifecycleCallbackFailures)
                    ~labels:[ "callback", "keeper_msg_async_on_worker_settled" ]
                    ();
                  Log.Keeper.error
                    "keeper_msg_async: on_worker_settled callback failed request_id=%s status=%s error=%s"
                    request_id
                    (match settlement with
                     | Status_settlement { status; _ } -> status_to_string status
                     | Settlement_projection_error _ -> "projection_error")
                    (Printexc.to_string exn))
          in
          let persist_abort_status ~attempted_status reason =
            match notify_aborted reason with
            | Ok () -> set_status_protected key attempted_status
            | Error callback_error ->
              set_status_protected
                key
                (Persistence_failed
                   { attempted_status = status_to_string attempted_status
                   ; reason = callback_error
                   })
          in
          let background_start_failed reason =
            let reason =
              Printf.sprintf
                "keeper_msg request was persisted but its background worker could not start: %s"
                reason
            in
            (* No worker scope was admitted, so [on_worker_aborted] does not
               own this path. The synchronous submit caller emits the single
               rejected transport terminal; invoking the callback here would
               publish a false cancellation first and duplicate transcript
               persistence. *)
            ignore
              (set_status_protected key (Lost { reason }) : worker_settlement option);
            Error (Background_fork_failed { request_id; reason })
          in
          let worker_started = Atomic.make false in
          (match
          Eio.Fiber.fork_daemon ~sw:background_sw (fun () ->
    Atomic.set worker_started true;
    let running_settlement =
      set_status_protected ~preserve_terminal:true key Running
    in
    match running_settlement with
    | Some (Status_settlement { status; _ } as settlement)
      when is_terminal_status status ->
      (* A failed Running write can durably commit its Persistence_failed
         marker and remove the runtime row. Project that exact settlement
         before stopping: falling through to worker admission would
         misclassify it as runtime cancellation and lose the durable SSOT. *)
      notify_settled settlement;
      `Stop_daemon
    | Some (Settlement_projection_error _ as settlement) ->
      notify_settled settlement;
      `Stop_daemon
    | Some (Status_settlement _) | None ->
      (* [f] owns any terminal signal it emits on its own side channels while
         it runs (e.g. push_worker_event in server_routes_http_keeper_stream's
         process_single_turn). Every catch arm below fires exactly when [f] was
         cut off before reaching that code, so the caller's channel would
         otherwise see nothing — see masc#23924. Eio.Cancel.protect matches
         set_status_protected above: at these catch sites the ambient switch
         may still be tearing down, so an unprotected call could itself be
         cancelled before the callback runs. *)
      let result =
        try
          Eio.Switch.run (fun req_sw ->
          let admission =
            with_lock (fun () ->
              Request_table.replace active_switches key req_sw;
              match Request_table.find_opt pending key with
              | Some { status = Queued | Running; _ } -> `Run
              | Some { status = Cancelling _; _ } -> `Operator_cancelled
              | Some
                  { status =
                      ((Done _ | Lost _ | Cancelled _ | Persistence_failed _) as
                       status)
                  ; _
                  } ->
                `Already_settled status
              | None -> `Preempted "keeper_msg request disappeared before worker start")
          in
          (match admission with
           | `Run -> ()
           | `Operator_cancelled -> raise CancelledByOperator
           | `Already_settled status -> raise (Worker_already_settled status)
           | `Preempted reason -> raise (Worker_preempted reason));
          let result = f req_sw in
          Done { ok = tool_result_success result; body = tool_result_body result })
      with
      | CancelledByOperator ->
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            persist_abort_status
              ~attempted_status:(operator_cancelled_status ())
              (Worker_cancelled
                 { cancelled_by = Operator_request
                 ; reason = operator_cancel_reason
                 })
            |> Option.iter notify_settled);
        operator_cancelled_status ()
      | Worker_preempted reason ->
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            persist_abort_status
              ~attempted_status:(runtime_cancelled_status ())
              (Worker_cancelled { cancelled_by = Runtime_cancellation; reason })
            |> Option.iter notify_settled);
        runtime_cancelled_status ()
      | Worker_already_settled status ->
        clear_active_switch key;
        notify_settled
          (Status_settlement
             { status
             ; durability = Volatile_persistence_failure
             ; origin = Transition_commit
             });
        status
      | Eio.Cancel.Cancelled _ as e ->
        (* [notify_aborted] observes callback exceptions without letting one
           request fail the server root switch. The switch-table release must
           still be exception-safe because cancellation cleanup below can be
           interrupted by unrelated bookkeeping failures.
           [clear_active_switch] is a mutex-guarded [Request_table.remove] and cannot
           itself raise, so the finally carries no [Finally_raised] risk. *)
        Fun.protect
          ~finally:(fun () -> clear_active_switch key)
          (fun () ->
            persist_abort_status
              ~attempted_status:(runtime_cancelled_status ())
              (Worker_cancelled
                 { cancelled_by = Runtime_cancellation
                 ; reason =
                     "keeper_msg worker was cancelled by runtime before terminal result"
                 })
            |> Option.iter notify_settled);
        raise e
      | exn ->
        Done
          { ok = false
          ; body = Printf.sprintf "keeper_msg failed: %s" (Printexc.to_string exn)
          }
      in
      set_status_protected ~preserve_terminal:true key result
      |> Option.iter notify_settled;
      clear_active_switch key;
      `Stop_daemon)
        with
        | () ->
          if Atomic.get worker_started
          then Ok { request_id; acceptance = Durably_accepted }
          else (
            match Eio.Switch.get_error background_sw with
            | None ->
              (* Eio accepted the daemon. A child can remain unscheduled here,
                 but Eio only drops it when the target switch is already
                 cancelling. *)
              Ok { request_id; acceptance = Durably_accepted }
            | Some cause -> background_start_failed (Printexc.to_string cause))
        | exception exn ->
          background_start_failed (Printexc.to_string exn))))))
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
        (match load_record_canonical_located ~base_path ~request_id with
         | Located (entry, _, _source_path) ->
           (match owner_rejection ~caller entry with
            | Some rejection -> Rejected rejection
            | None ->
              (match entry.status with
               | Queued | Running | Cancelling _ ->
                 (* A poller cannot prove that another process does not own
                    this worker. Only the exclusive startup recovery boundary
                    may convert disk-only non-terminal state to [Lost]. *)
                 Found entry
               | Done _ | Lost _ | Cancelled _ | Persistence_failed _ -> Found entry))
         | Located_absent -> Absent
         | Located_unreadable reason -> Unreadable reason
         | Located_rejected rejection -> Rejected rejection))
;;

(** List only this caller lane; cross-lane rows are intentionally omitted. *)
let list_for_keeper ~base_path ~caller ?keeper_name () :
    (entry list, access_rejection) result =
  let* base_path, caller = resolve_access_identity ~base_path ~caller in
  let entries =
    Eio.Mutex.use_ro mu (fun () ->
      Request_table.fold
        (fun _id entry acc ->
           if
             (not (String.equal entry.base_path base_path))
             || Option.is_some (owner_rejection ~caller entry)
           then acc
           else
             match entry.status, keeper_name with
             | (Done _ | Lost _ | Cancelled _ | Persistence_failed _), _ -> acc
             | (Queued | Running | Cancelling _), Some name
               when not (String.equal entry.keeper_name name) -> acc
             | (Queued | Running | Cancelling _), (Some _ | None) -> entry :: acc)
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
      let elapsed = Time_compat.now () -. e.submitted_at in
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
    | Cancelling { reason; cancelled_by } ->
      fields
      @ [ "ok", `Bool false
        ; ( "result"
          , `Assoc
              [ "cancellation_requested", `Bool true
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

let cancel_disk_record ~base_path ~caller ~request_id =
  match load_record_canonical_located ~base_path ~request_id with
  | Located_absent -> Cancel_not_found
  | Located_unreadable reason -> Cancel_unreadable reason
  | Located_rejected rejection -> Cancel_rejected rejection
  | Located (entry, _, _source_path) ->
    (match owner_rejection ~caller entry with
     | Some rejection -> Cancel_rejected rejection
     | None when is_terminal_status entry.status ->
       Cancel_already_terminal entry.status
     | None ->
       (* Process-local absence is not proof of worker absence: stdio and
          HTTP runtimes can observe the same BasePath. Startup recovery runs
          only under the exclusive server ownership boundary; an arbitrary
          cancel caller must not steal another process's live request. *)
       Cancel_worker_ownership_unknown entry.status)
;;

let signal_operator_cancel request_sw =
  match Atomic.get cancel_signal_hook_for_testing with
  | None -> Eio.Switch.fail request_sw CancelledByOperator
  | Some signal -> signal request_sw CancelledByOperator
;;

let cancel ~base_path ~caller request_id : cancel_result =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Cancel_rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Cancel_rejected Invalid_request_id
    else (
      let key = request_key ~base_path ~submitted_by:caller ~request_id in
      match transition_lock_for_key key with
      | None -> cancel_disk_record ~base_path ~caller ~request_id
      | Some transition_lock ->
        let result =
          Eio.Mutex.use_rw ~protect:true transition_lock (fun () ->
            let current =
              with_lock (fun () ->
                match
                  Request_table.find_opt transition_locks key,
                  Request_table.find_opt pending key
                with
                | None, None -> `Load_disk
                | Some owned, Some entry when owned == transition_lock -> `Entry entry
                | Some _, Some _ ->
                  `Invariant
                    "request transition lock ownership changed during cancellation"
                | Some _, None ->
                  `Invariant
                    "request transition lock exists without an active request entry"
                | None, Some _ ->
                  `Invariant
                    "active request entry exists without its transition lock")
            in
            match current with
            | `Load_disk -> `Load_disk
            | `Invariant reason -> `Result (Cancel_state_invariant_failed { reason })
            | `Entry entry ->
              (match owner_rejection ~caller entry with
               | Some rejection -> `Result (Cancel_rejected rejection)
               | None ->
                 let commit_and_signal cancelling =
                    let persistence =
                      match
                        persist_entry cancelling
                        |> observe_persist_error ~operation:"operator_cancel" cancelling
                      with
                      | Ok () -> Ok `Durable
                      | Error (Write_failed (Published_uncertain error)) ->
                        Ok
                          (`Volatile
                              (Keeper_fs.durable_write_error_to_string error))
                      | Error error ->
                        Error
                          (Cancel_persistence_failed
                             { reason = persist_error_to_string error })
                    in
                    (match persistence with
                     | Error result -> `Result result
                     | Ok durability ->
                       let publication =
                         with_lock (fun () ->
                           match
                             Request_table.find_opt transition_locks key,
                             Request_table.find_opt pending key
                           with
                           | Some owned, Some _ when owned == transition_lock ->
                             Request_table.replace pending key cancelling;
                             `Published (Request_table.find_opt active_switches key)
                           | _ ->
                             `Invariant
                               "request runtime state disappeared after cancellation was published")
                       in
                       let accepted_result =
                         match durability with
                         | `Durable -> Cancellation_requested Durably_committed
                         | `Volatile reason ->
                           Cancellation_requested
                             (Published_unconfirmed { reason })
                       in
                       (match publication with
                        | `Invariant reason ->
                          `Result (Cancel_state_invariant_failed { reason })
                        | `Published None -> `Result accepted_result
                        | `Published (Some request_sw) ->
                          (try
                             signal_operator_cancel request_sw;
                             `Result accepted_result
                           with
                           | Eio.Cancel.Cancelled _ as e -> raise e
                           | exn ->
                             `Result
                               (Cancel_worker_signal_failed
                                  { durability =
                                      (match durability with
                                       | `Durable -> Durably_committed
                                       | `Volatile reason ->
                                         Published_unconfirmed { reason })
                                  ; reason = Printexc.to_string exn
                                  }))))
                 in
                 (match entry.status with
                  | Done _ | Lost _ | Cancelled _ | Persistence_failed _ ->
                    `Result (Cancel_already_terminal entry.status)
                  | Cancelling _ ->
                    (* The operator's next explicit cancel call is the retry
                       boundary. Re-persist the same intent to recover an exact
                       durability result, then signal the currently owned
                       request switch again. No timer or retry count guesses
                       whether the worker is still live. *)
                    commit_and_signal entry
                  | Queued | Running ->
                    commit_and_signal
                      { entry with
                        status = operator_cancelling_status ()
                      ; completed_at = None
                      }))
              )
        in
        (match result with
         | `Load_disk -> cancel_disk_record ~base_path ~caller ~request_id
         | `Result result -> result))
;;

module For_testing = struct
  let record_schema_version = record_schema_version
  let is_safe_request_id = is_safe_request_id
  let forget ~base_path ~caller ~request_id =
    match resolve_access_identity ~base_path ~caller with
    | Error _ -> ()
    | Ok (base_path, submitted_by) ->
      let key = request_key ~base_path ~submitted_by ~request_id in
      with_lock (fun () ->
        match Request_table.find_opt transition_locks key with
        | None -> ()
        | Some _ ->
          Store_transition_table.remove
            reserved_request_ids
            ({ base_path; request_id } : Store_transition_key.t);
          Request_table.remove pending key;
          Request_table.remove transition_locks key)
  ;;

  let clear () =
    Atomic.set durable_write_hook_for_testing None;
    Atomic.set durable_remove_hook_for_testing None;
    Atomic.set cancel_signal_hook_for_testing None;
    Atomic.set request_id_hook_for_testing None;
    Atomic.set integrity_projection_hook_for_testing None;
    with_lock (fun () ->
      Request_table.clear pending;
      Request_table.clear transition_locks;
      Request_table.clear active_switches;
      Store_transition_table.clear store_transition_locks;
      Store_transition_table.clear reserved_request_ids;
      Keeper_submission_table.clear keeper_submission_locks)
  ;;
  let active_record_path = active_record_path
  let terminal_record_path = terminal_record_path
  let legacy_record_path = legacy_record_path
  let load_record = load_record
  let recover_lost_disk_records = recover_lost_disk_records
  let set_durable_write_hook hook =
    Atomic.set durable_write_hook_for_testing hook
  ;;
  let set_durable_remove_hook hook =
    Atomic.set durable_remove_hook_for_testing hook
  ;;
  let set_cancel_signal_hook hook =
    Atomic.set cancel_signal_hook_for_testing hook
  ;;
  let set_request_id_hook hook = Atomic.set request_id_hook_for_testing hook
  let set_integrity_projection_hook hook =
    Atomic.set integrity_projection_hook_for_testing hook
  ;;
  let reserved_request_id_count () =
    Eio.Mutex.use_ro mu (fun () -> Store_transition_table.length reserved_request_ids)
  ;;
  let active_switch_count () =
    Eio.Mutex.use_ro mu (fun () -> Request_table.length active_switches)
  ;;

end
