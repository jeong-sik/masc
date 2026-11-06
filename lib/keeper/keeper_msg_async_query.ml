open Result.Syntax
open Keeper_msg_async_types
open Keeper_msg_async_record
open Keeper_msg_async_state
open Keeper_msg_async_store
open Keeper_msg_async_lifecycle

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
         | Located (entry, _) ->
           (match owner_rejection ~caller entry with
            | Some rejection -> Rejected rejection
            | None ->
              (match entry.status with
               | Queued | Running | Cancelling _ ->
                 (* A poller cannot prove that another process does not own
                    this worker. Only the exclusive startup recovery boundary
                    may convert disk-only non-terminal state to [Lost]. *)
                 Found entry
               | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ -> Found entry))
         | Located_absent -> Absent
         | Located_unreadable reason -> Unreadable reason
         | Located_rejected rejection -> Rejected rejection))
;;

let load_canonical_request ~base_path ~caller request_id =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Rejected rejection
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id) then Rejected Invalid_request_id
    else with_canonical_request_read ~base_path ~caller ~request_id (fun () ->
      match load_record_canonical_located ~base_path ~request_id with
      | Located_absent -> Absent
      | Located_unreadable reason -> Unreadable reason
      | Located_rejected rejection -> Rejected rejection
      | Located (entry, _) ->
        match owner_rejection ~caller entry with
        | Some rejection -> Rejected rejection
        | None -> Found entry)
;;

let with_canonical_durable_terminal ~base_path ~caller request_id ~f =
  match resolve_access_identity ~base_path ~caller with
  | Error rejection -> Error (Canonical_terminal_access_rejected rejection)
  | Ok (base_path, caller) ->
    if not (is_safe_request_id request_id)
    then Error (Canonical_terminal_access_rejected Invalid_request_id)
    else
      with_canonical_request_read ~base_path ~caller ~request_id (fun () ->
        let key = request_key ~base_path ~submitted_by:caller ~request_id in
        match
          Eio.Mutex.use_ro mu (fun () -> Request_table.find_opt pending key)
        with
        | Some entry when is_terminal_status entry.status ->
          Error (Canonical_terminal_publication_ambiguous entry.status)
        | Some entry -> Error (Canonical_terminal_runtime_active entry.status)
        | None ->
          (match load_record_canonical_located ~base_path ~request_id with
           | Located_absent -> Error Canonical_terminal_absent
           | Located_unreadable reason ->
             Error (Canonical_terminal_unreadable reason)
           | Located_rejected rejection ->
             Error (Canonical_terminal_access_rejected rejection)
           | Located (entry, location) ->
             (match owner_rejection ~caller entry with
              | Some rejection ->
                Error (Canonical_terminal_access_rejected rejection)
              | None ->
                if not (is_terminal_status entry.status)
                then Error (Canonical_terminal_nonterminal entry.status)
                else
                  match location with
                  | Terminal_location -> Ok (f { terminal_entry = entry })
                  | Active_location ->
                    Error
                      (Canonical_terminal_noncanonical_location entry.status))))
;;

let load_canonical_durable_terminal ~base_path ~caller request_id =
  with_canonical_durable_terminal ~base_path ~caller request_id ~f:Fun.id
;;

let queued_proof_of_record ~caller ~location ~local (entry : entry) =
  match owner_rejection ~caller entry with
  | Some rejection -> Error (Canonical_queued_access_rejected rejection)
  | None ->
    match entry.status with
    | Running | Cancelling _ | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
      Error (Canonical_queued_not_queued entry.status)
    | Queued ->
      match location with
      | Terminal_location -> Error (Canonical_queued_noncanonical_location entry.status)
      | Active_location ->
        match local with
        | None -> Ok { queued_entry = entry }
        | Some local ->
          match local.status with
          | Running | Cancelling _ -> Error (Canonical_queued_runtime_nonqueued local.status)
          | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
            Error (Canonical_queued_publication_ambiguous local.status)
          | Queued ->
            if same_entry_record local entry then Ok { queued_entry = entry }
            else Error Canonical_queued_runtime_conflict
;;

let load_canonical_durable_queued ~base_path ~caller request_id =
  let* base_path, caller =
    resolve_access_identity ~base_path ~caller
    |> Result.map_error (fun rejection -> Canonical_queued_access_rejected rejection)
  in
  if not (is_safe_request_id request_id)
  then Error (Canonical_queued_access_rejected Invalid_request_id)
  else
    with_canonical_request_read ~base_path ~caller ~request_id (fun () ->
      (* Canonical disk authority takes precedence over any cached reservation.
         The existing decoder also refuses unreadable/conflicting partitions. *)
      match load_record_canonical_located ~base_path ~request_id with
      | Located_absent -> Error Canonical_queued_absent
      | Located_unreadable reason -> Error (Canonical_queued_unreadable reason)
      | Located_rejected rejection -> Error (Canonical_queued_access_rejected rejection)
      | Located (entry, location) ->
        let key = request_key ~base_path ~submitted_by:caller ~request_id in
        let local = Eio.Mutex.use_ro mu (fun () -> Request_table.find_opt pending key) in
        queued_proof_of_record ~caller ~location ~local entry)
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
             | (Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _), _ -> acc
             | (Queued | Running | Cancelling _), Some name
               when not (String.equal entry.keeper_name name) -> acc
             | (Queued | Running | Cancelling _), (Some _ | None) -> entry :: acc)
        pending
        [])
    |> List.sort (fun a b ->
         let cmp = Float.compare b.submitted_at a.submitted_at in
         if cmp <> 0 then cmp else String.compare a.request_id b.request_id)
  in
  Ok entries
;;

let entry_to_fields (e : entry) =
  let now =
    match e.completed_at with
    | Some completed_at -> completed_at
    | None -> Time_compat.now ()
  in
  Keeper_msg_async_record.entry_to_fields ~now e
;;

let entry_to_json (e : entry) = `Assoc (entry_to_fields e)
;;
