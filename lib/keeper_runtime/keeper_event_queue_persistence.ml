module Owner_lock = Keeper_event_queue_owner_lock
module State = Keeper_event_queue_state

type lease_kind = State.lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason = State.requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery
  | Retry_after_observed
  | Context_compaction_retry
  | Approval_grant_unconsumed
  | Approval_grant_state_unavailable

type escalation_reason = State.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }

type settlement = State.settlement =
  | Ack
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type lease = State.lease
type transition_receipt = State.transition_receipt
type outbox_entry = State.outbox_entry

type settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt
  | Committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

let lease_stimuli (lease : lease) = lease.stimuli
let lease_kind = State.lease_kind

let snapshot_filename = "event-queue.json"
let settlement_wal_filename = "event-queue-settlements.jsonl"
let unsupported_inflight_filename = "event-queue-inflight.json"

let owner_error_to_string = Owner_lock.resolve_error_to_string

let resolve_owner ~base_path ~keeper_name =
  match Owner_lock.resolve ~base_path ~keeper_name with
  | Ok owner -> Ok owner
  | Error error -> Error (owner_error_to_string error)
;;

let keeper_name_of_owner owner =
  Owner_lock.keeper_name owner |> Keeper_id.Keeper_name.to_string
;;

let keeper_runtime_dir_of_owner owner =
  Filename.concat
    (Common.keepers_runtime_dir_of_base ~base_path:(Owner_lock.base_path owner))
    (keeper_name_of_owner owner)
;;

let snapshot_path_of_owner owner =
  Filename.concat (keeper_runtime_dir_of_owner owner) snapshot_filename
;;

let settlement_wal_path_of_owner owner =
  Filename.concat (keeper_runtime_dir_of_owner owner) settlement_wal_filename
;;

let compact_settlement_wal_unlocked owner =
  let path = settlement_wal_path_of_owner owner in
  match
    Fs_compat.rewrite_private_file_durable_locked_result path (fun existing ->
      (if String.equal existing "" then None else Some ""), ())
  with
  | Ok () -> Ok ()
  | Error detail ->
    Error
      (Printf.sprintf
         "failed to compact checkpointed settlement WAL keeper=%s path=%s: %s"
         (keeper_name_of_owner owner)
         path
         detail)
;;

let unsupported_inflight_path_of_owner owner =
  Filename.concat (keeper_runtime_dir_of_owner owner) unsupported_inflight_filename
;;

let save_json_atomic path json =
  match
    try Ok (Fs_compat.mkdir_p (Filename.dirname path)) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok () ->
    json
    |> Safe_ops.sanitize_json_utf8
    |> Yojson.Safe.pretty_to_string
    |> Fs_compat.save_file_atomic path
;;

let save_state_unlocked owner state =
  let keeper_name = keeper_name_of_owner owner in
  let path = snapshot_path_of_owner owner in
  match save_json_atomic path (State.to_yojson state) with
  | Ok () -> Ok ()
  | Error message ->
    Error
      (Printf.sprintf
         "failed to persist keeper=%s path=%s: %s"
         keeper_name
         path
         message)
;;

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

let snapshot_read_error_kind_to_string = function
  | Invalid_path -> "invalid_path"
  | Read_failed -> "read_failed"
  | Parse_failed -> "parse_failed"
;;

let read_json_if_present path =
  try
    if Sys.file_exists path
    then
      (match Safe_ops.read_json_file_safe path with
       | Ok json -> Ok (Some json)
       | Error message ->
         Error (Printf.sprintf "failed to read %s: %s" path message))
    else Ok None
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error (Printf.sprintf "failed to inspect %s: %s" path (Printexc.to_string exn))
;;

let schema_field = function
  | `Assoc fields ->
    (match List.assoc_opt "schema" fields with
     | Some (`String schema) -> Ok schema
     | Some _ -> Error "snapshot schema must be a string"
     | None -> Error "snapshot missing required field schema")
  | _ -> Error "snapshot must be a JSON object"
;;

type primary_snapshot =
  | Primary_missing
  | Primary_current of State.t

let read_primary_unlocked owner =
  let path = snapshot_path_of_owner owner in
  match read_json_if_present path with
  | Error _ as error -> error
  | Ok None -> Ok Primary_missing
  | Ok (Some json) ->
    (match schema_field json with
     | Error message -> Error (Printf.sprintf "%s: %s" path message)
     | Ok schema when String.equal schema State.schema ->
       (match State.of_yojson json with
        | Ok state -> Ok (Primary_current state)
        | Error message -> Error (Printf.sprintf "%s: %s" path message))
     | Ok schema ->
       Error (Printf.sprintf "%s: unsupported snapshot schema %s" path schema))
;;

let reject_unsupported_inflight owner =
  let path = unsupported_inflight_path_of_owner owner in
  try
    if Sys.file_exists path
    then
      Error
        (Printf.sprintf
           "unsupported event queue sidecar remains at %s; remove it before starting the keeper"
           path)
    else Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error (Printf.sprintf "failed to inspect unsupported sidecar %s: %s" path (Printexc.to_string exn))
;;

let bump_revision state =
  if Int64.equal (State.revision state) Int64.max_int
  then Error "event queue revision exhausted"
  else Ok (State.with_revision (Int64.succ (State.revision state)) state)
;;

let settlement_wal_entry_to_line owner receipt =
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.settlement.v1"
    ; "base_path", `String (Owner_lock.base_path owner)
    ; "keeper_name", `String (keeper_name_of_owner owner)
    ; "receipt", State.transition_receipt_to_yojson receipt
    ]
  |> Yojson.Safe.to_string
  |> fun row -> row ^ "\n"
;;

let settlement_wal_receipt_of_json owner = function
  | `Assoc fields ->
    (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
     | [ ("base_path", `String base_path)
       ; ("keeper_name", `String keeper_name)
       ; ("receipt", receipt)
       ; ("schema", `String schema)
       ] ->
       if not (String.equal schema "masc.keeper_event_queue.settlement.v1")
       then Error (Printf.sprintf "unsupported settlement WAL schema: %s" schema)
       else if
         not
           (String.equal base_path (Owner_lock.base_path owner)
            && String.equal keeper_name (keeper_name_of_owner owner))
       then Error "settlement WAL row owner does not match its Keeper lane"
       else State.transition_receipt_of_yojson receipt
     | _ -> Error "settlement WAL row fields are not exact")
  | _ -> Error "settlement WAL row must be a JSON object"
;;

let replay_settlement_wal_bytes owner state bytes =
  let rec replay state = function
    | [] | [ "" ] -> Ok state
    | "" :: _ -> Error "settlement WAL contains an empty row"
    | line :: rest ->
      (match
         try Ok (Yojson.Safe.from_string line) with
         | Yojson.Json_error detail -> Error detail
       with
       | Error detail -> Error ("invalid settlement WAL JSON: " ^ detail)
       | Ok json ->
         (match settlement_wal_receipt_of_json owner json with
          | Error _ as error -> error
          | Ok receipt ->
            (match State.replay_transition_receipt receipt state with
             | Error _ as error -> error
             | Ok state -> replay state rest)))
  in
  replay state (String.split_on_char '\n' bytes)
;;

let replay_settlement_wal_unlocked owner state =
  let path = settlement_wal_path_of_owner owner in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Error error ->
    Error
      (Printf.sprintf
         "failed to read settlement WAL keeper=%s path=%s: %s"
         (keeper_name_of_owner owner)
         path
         (Fs_compat.Private_jsonl_slice.error_to_string error))
  | Ok { bytes = ""; _ } -> Ok state
  | Ok slice ->
    (match replay_settlement_wal_bytes owner state slice.bytes with
     | Error detail -> Error (Printf.sprintf "failed to replay %s: %s" path detail)
     | Ok replayed ->
       (match bump_revision replayed with
        | Error _ as error -> error
        | Ok replayed ->
          (match save_state_unlocked owner replayed with
           | Ok () ->
             (match compact_settlement_wal_unlocked owner with
              | Ok () -> Ok replayed
              | Error detail ->
                Error
                  ("settlement WAL checkpoint recovered but compaction failed: "
                   ^ detail))
           | Error detail ->
             Error
               (Printf.sprintf
                  "settlement WAL is committed but checkpoint replay failed: %s"
                  detail))))
;;

let load_state_unlocked owner =
  match reject_unsupported_inflight owner with
  | Error _ as error -> error
  | Ok () ->
    (match read_primary_unlocked owner with
     | Error _ as error -> error
     | Ok (Primary_current state) -> replay_settlement_wal_unlocked owner state
     | Ok Primary_missing -> replay_settlement_wal_unlocked owner State.empty)
;;

let load_state_result ~base_path ~keeper_name =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try Owner_lock.with_durable_lock owner (fun () -> load_state_unlocked owner) with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue state load raised keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            (snapshot_path_of_owner owner)
            (Printexc.to_string exn)))
;;

let active_lease_result ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map State.active_lease
;;

let transition_outbox_result ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map State.transition_outbox
;;

let queue_of_stimuli stimuli =
  List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty stimuli
;;

let inflight_queue state =
  State.leases state
  |> List.concat_map (fun (lease : lease) -> lease.stimuli)
  |> Keeper_event_queue.uniq_stimuli
  |> queue_of_stimuli
;;

let replay_queue state =
  Keeper_event_queue.prepend_list
    (Keeper_event_queue.to_list (inflight_queue state))
    (State.pending state)
  |> Keeper_event_queue.dedup_by_identity
;;

let load_with_projection ~projection ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map projection
;;

let load_result ~base_path ~keeper_name =
  load_with_projection ~projection:replay_queue ~base_path ~keeper_name
;;

let unavailable_projection_exn ~keeper_name message =
  Failure
    (Printf.sprintf
       "event queue state unavailable keeper=%s: %s"
       keeper_name
       message)
;;

let load ~base_path ~keeper_name =
  match load_result ~base_path ~keeper_name with
  | Error message -> raise (unavailable_projection_exn ~keeper_name message)
  | Ok queue ->
    if not (Keeper_event_queue.is_empty queue)
    then
      Log.Keeper.info
        "event_queue_snapshot: restored %s for keeper=%s"
        (Keeper_event_queue.summary queue)
        keeper_name;
    queue
;;

let load_pending ~base_path ~keeper_name =
  match load_with_projection ~projection:State.pending ~base_path ~keeper_name with
  | Ok queue -> queue
  | Error message -> raise (unavailable_projection_exn ~keeper_name message)
;;

let load_pending_result ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map State.pending
;;

type snapshot_pair =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  }

type snapshot_pair_with_errors =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  ; read_errors : snapshot_read_error list
  }

let diagnose_snapshot_read_error ~base_path ~keeper_name message =
  match resolve_owner ~base_path ~keeper_name with
  | Error invalid -> [ { kind = Invalid_path; path = None; message = invalid } ]
  | Ok owner ->
    let primary = snapshot_path_of_owner owner in
    let unsupported = unsupported_inflight_path_of_owner owner in
    let inspect path =
      try
        if not (Sys.file_exists path)
        then None
        else
          match Safe_ops.read_json_file_safe path with
          | Error read_message ->
            Some { kind = Read_failed; path = Some path; message = read_message }
          | Ok _ -> Some { kind = Parse_failed; path = Some path; message }
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Some
          { kind = Read_failed
          ; path = Some path
          ; message = Printexc.to_string exn
          }
    in
    match inspect unsupported with
    | Some _ -> [ { kind = Parse_failed; path = Some unsupported; message } ]
    | None ->
      (match inspect primary with
       | Some error -> [ error ]
       | None -> [ { kind = Parse_failed; path = None; message } ])
;;

let load_snapshot_pair_with_errors ~base_path ~keeper_name =
  match load_state_result ~base_path ~keeper_name with
  | Ok state ->
    { pending = State.pending state; inflight = inflight_queue state; read_errors = [] }
  | Error message ->
    { pending = Keeper_event_queue.empty
    ; inflight = Keeper_event_queue.empty
    ; read_errors = diagnose_snapshot_read_error ~base_path ~keeper_name message
    }
;;

let load_snapshot_pair ~base_path ~keeper_name =
  let snapshot = load_snapshot_pair_with_errors ~base_path ~keeper_name in
  { pending = snapshot.pending; inflight = snapshot.inflight }
;;

type snapshot_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

let discover_keeper_names_with_snapshots ~base_path =
  match Owner_lock.canonical_base_path base_path with
  | Error error ->
    { keeper_names = []; read_error = Some (owner_error_to_string error) }
  | Ok base_path ->
    let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
    (try
       if not (Sys.file_exists keepers_dir)
       then { keeper_names = []; read_error = None }
       else if not (Sys.is_directory keepers_dir)
       then
         { keeper_names = []
         ; read_error = Some ("keepers runtime path is not a directory: " ^ keepers_dir)
         }
       else
         let names, errors =
           Sys.readdir keepers_dir
           |> Array.fold_left
                (fun (names, errors) name ->
                   let keeper_dir = Filename.concat keepers_dir name in
                   let primary = Filename.concat keeper_dir snapshot_filename in
                   if
                     not (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir)
                     || not (Sys.file_exists primary)
                   then names, errors
                   else
                     match Keeper_id.Keeper_name.of_string name with
                     | Ok keeper_name ->
                       Keeper_id.Keeper_name.to_string keeper_name :: names, errors
                     | Error reason ->
                       names,
                       Printf.sprintf
                         "invalid keeper name with durable event queue snapshot: %s"
                         reason
                       :: errors)
                ([], [])
         in
         { keeper_names = List.sort_uniq String.compare names
         ; read_error =
             (match List.rev errors with
              | [] -> None
              | errors -> Some (String.concat "; " errors))
         }
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       { keeper_names = []
       ; read_error =
           Some
             (Printf.sprintf
                "failed to discover event queue snapshots under %s: %s"
                keepers_dir
                (Printexc.to_string exn))
       })
;;

let commit_transform_unlocked owner ~after_commit transform =
  match load_state_unlocked owner with
  | Error _ as error -> error
  | Ok current ->
    (match transform current with
     | Error _ as error -> error
     | Ok (next, value) when next == current -> Ok value
     | Ok (next, value) ->
       (match bump_revision next with
        | Error _ as error -> error
        | Ok next ->
          (match save_state_unlocked owner next with
           | Error _ as error -> error
           | Ok () ->
             after_commit (State.pending next);
             Ok value)))
;;

let commit_transform ~base_path ~keeper_name ~after_commit transform =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         commit_transform_unlocked owner ~after_commit transform)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue transaction raised keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            (snapshot_path_of_owner owner)
            (Printexc.to_string exn)))
;;

let update_checked_result ?(after_commit = fun () -> ()) ~base_path ~keeper_name f =
  commit_transform
    ~base_path
    ~keeper_name
    ~after_commit:(fun _pending -> after_commit ())
    (fun state ->
       match f (State.pending state) with
       | Error _ as error -> error
       | Ok pending -> Ok (State.with_pending pending state, ()))
;;

type enqueue_stimulus_result =
  | Enqueued
  | Already_present

let state_accounts_for_stimulus state stimulus =
  let same candidate =
    Keeper_event_queue.stimulus_identity_equal candidate stimulus
  in
  List.exists same (Keeper_event_queue.to_list (State.pending state))
  || List.exists
       (fun (lease : lease) -> List.exists same lease.stimuli)
       (State.leases state)
  || List.exists
       (fun (entry : outbox_entry) -> List.exists same entry.stimuli)
       (State.transition_outbox state)
;;

let enqueue_stimulus_if_absent_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      stimulus
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    if state_accounts_for_stimulus state stimulus then
      Ok (state, Already_present)
    else
      let pending = Keeper_event_queue.enqueue (State.pending state) stimulus in
      Ok (State.with_pending pending state, Enqueued))
;;

let update_result ?after_commit ~base_path ~keeper_name f =
  update_checked_result ?after_commit ~base_path ~keeper_name (fun queue -> Ok (f queue))
;;

let update ~base_path ~keeper_name f =
  match update_result ~base_path ~keeper_name f with
  | Ok () -> ()
  | Error message ->
    Log.Keeper.error "event_queue_snapshot: update failed keeper=%s: %s" keeper_name message
;;

let persist ~base_path ~keeper_name queue =
  update ~base_path ~keeper_name (fun _ -> queue)
;;

let persist_snapshot ~base_path ~keeper_name snapshot =
  update ~base_path ~keeper_name (fun _ -> snapshot ())
;;

let claim_when_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~claimed_at
      ~ready
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    match State.claim_when ~claimed_at ~ready state with
    | Error _ as error -> error
    | Ok (state, lease) -> Ok (state, lease))
;;

let claim_board_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~claimed_at
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    match State.claim_board ~claimed_at state with
    | Error _ as error -> error
    | Ok (state, lease) -> Ok (state, lease))
;;

let commit_settlement_unlocked
      owner
      ~after_commit
      ~settled_at
      ~lease
      ~settlement
      current
  =
  match State.settle ~settled_at ~lease ~settlement current with
  | Error _ as error -> error
  | Ok (state, State.Already_settled receipt) ->
    Ok (Already_settled receipt, State.pending state)
  | Ok (state, State.Settled receipt) ->
    (match bump_revision state with
     | Error _ as error -> error
     | Ok checkpoint ->
       let suffix = settlement_wal_entry_to_line owner receipt in
       let path = settlement_wal_path_of_owner owner in
       (match
          Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
            path
            ~expected_end_offset:0
            suffix
        with
        | Error error ->
          Error
            (Printf.sprintf
               "settlement WAL commit failed keeper=%s path=%s: %s"
               (keeper_name_of_owner owner)
               path
               (Fs_compat.private_jsonl_append_error_to_string error))
        | Ok _committed_end_offset ->
          let pending = State.pending checkpoint in
          (match save_state_unlocked owner checkpoint with
           | Error detail ->
             Ok
               ( Committed_followup_failed
                   { receipt; stage = `Checkpoint; detail }
               , pending )
           | Ok () ->
             (match compact_settlement_wal_unlocked owner with
              | Error detail ->
                Ok
                  ( Committed_followup_failed
                      { receipt; stage = `Wal_compaction; detail }
                  , pending )
              | Ok () ->
                (match
                   try
                     after_commit pending;
                     Ok ()
                   with
                   | Eio.Cancel.Cancelled _ as exn ->
                     Error
                       ("pending projection cancelled after settlement commit: "
                        ^ Printexc.to_string exn)
                   | exn -> Error (Printexc.to_string exn)
                 with
                 | Ok () -> Ok (Settled receipt, pending)
                 | Error detail ->
                   Ok
                     ( Committed_followup_failed
                         { receipt; stage = `Projection; detail }
                     , pending ))))))
;;

let settle_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~settled_at
      ~lease
      ~settlement
      ()
  =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         match load_state_unlocked owner with
         | Error _ as error -> error
         | Ok state ->
           commit_settlement_unlocked
             owner
             ~after_commit
             ~settled_at
             ~lease
             ~settlement
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue settlement raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let prepare_registration_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~settled_at
      ()
  =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         match load_state_unlocked owner with
         | Error _ as error -> error
         | Ok state ->
           (match State.active_lease state with
            | None -> Ok (State.pending state)
            | Some lease ->
              (match
                 commit_settlement_unlocked
                   owner
                   ~after_commit
                   ~settled_at
                   ~lease
                   ~settlement:(Requeue Registration_recovery)
                   state
               with
               | Error _ as error -> error
               | Ok ((Settled _ | Already_settled _), pending) -> Ok pending
               | Ok (Committed_followup_failed { detail; _ }, _) ->
                 Error ("registration settlement committed with follow-up failure: " ^ detail))))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue registration settlement raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let mark_transition_projected_result ~base_path ~keeper_name ~transition_id =
  commit_transform
    ~base_path
    ~keeper_name
    ~after_commit:(fun _ -> ())
    (fun state ->
       match State.mark_transition_projected ~transition_id state with
       | Error _ as error -> error
       | Ok state -> Ok (state, ()))
;;

let record_inflight ~base_path ~keeper_name stimuli =
  match stimuli with
  | [] -> ()
  | _ ->
    (match
       commit_transform
         ~base_path
         ~keeper_name
         ~after_commit:(fun _ -> ())
         (fun state ->
            match State.add_legacy_inflight stimuli state with
            | Error _ as error -> error
            | Ok (state, _lease) -> Ok (state, ()))
     with
     | Ok () -> ()
     | Error message ->
       Log.Keeper.error
         "event_queue_snapshot: record legacy inflight failed keeper=%s: %s"
         keeper_name
         message)
;;

let ack_inflight ~base_path ~keeper_name stimuli =
  match
    commit_transform
      ~base_path
      ~keeper_name
      ~after_commit:(fun _ -> ())
      (fun state ->
         Ok (State.release_legacy_inflight stimuli state, ()))
  with
  | Ok () -> ()
  | Error message ->
    Log.Keeper.error "event_queue_snapshot: ack_inflight failed keeper=%s: %s" keeper_name message
;;

let remove_post_ids stimuli state =
  List.fold_left
    (fun (removed, state) (stimulus : Keeper_event_queue.stimulus) ->
       let newly_removed, state = State.remove_by_post_id stimulus.post_id state in
       Keeper_event_queue.uniq_stimuli (removed @ newly_removed), state)
    ([], state)
    stimuli
;;

let ack_consumed ~base_path ~keeper_name stimuli =
  commit_transform
    ~base_path
    ~keeper_name
    ~after_commit:(fun _ -> ())
    (fun state ->
       let _removed, state = remove_post_ids stimuli state in
       Ok (state, ()))
;;

let drop_by_post_id
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~post_id
      ()
  =
  commit_transform
    ~base_path
    ~keeper_name
    ~after_commit
    (fun state ->
       let removed, state = State.remove_by_post_id post_id state in
       Ok (state, removed))
;;

let queue_oldest_arrived_at queue =
  queue
  |> Keeper_event_queue.to_list
  |> List.fold_left
       (fun oldest (stimulus : Keeper_event_queue.stimulus) ->
          match oldest with
          | None -> Some stimulus.arrived_at
          | Some value -> Some (Float.min value stimulus.arrived_at))
       None
;;

let min_float_opt left right =
  match left, right with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some left, Some right -> Some (Float.min left right)
;;

let json_of_float_opt = function
  | None -> `Null
  | Some value -> `Float value
;;

let age_seconds_json ~now = function
  | None -> `Null
  | Some timestamp -> `Float (Float.max 0.0 (now -. timestamp))
;;

type keeper_summary =
  { keeper_name : string
  ; pending_count : int
  ; inflight_count : int
  ; pending_oldest : float option
  ; inflight_oldest : float option
  ; oldest : float option
  ; outbox_count : int
  ; counts_complete : bool
  ; read_errors : string list
  }

let keeper_summary ~base_path keeper_name =
  match load_state_result ~base_path ~keeper_name with
  | Ok state ->
    let pending = State.pending state in
    let inflight = inflight_queue state in
    let pending_oldest = queue_oldest_arrived_at pending in
    let inflight_oldest = queue_oldest_arrived_at inflight in
    let outbox = State.transition_outbox state in
    { keeper_name
    ; pending_count = Keeper_event_queue.length pending
    ; inflight_count = Keeper_event_queue.length inflight
    ; pending_oldest
    ; inflight_oldest
    ; oldest = min_float_opt pending_oldest inflight_oldest
    ; outbox_count = List.length outbox
    ; counts_complete = true
    ; read_errors = []
    }
  | Error message ->
    let read_errors =
      diagnose_snapshot_read_error ~base_path ~keeper_name message
      |> List.map (fun error -> error.message)
    in
    { keeper_name
    ; pending_count = 0
    ; inflight_count = 0
    ; pending_oldest = None
    ; inflight_oldest = None
    ; oldest = None
    ; outbox_count = 0
    ; counts_complete = false
    ; read_errors
    }
;;

let keeper_summary_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "pending_count", `Int summary.pending_count
    ; "inflight_count", `Int summary.inflight_count
    ; "total_count", `Int (summary.pending_count + summary.inflight_count)
    ; "oldest_arrived_at_unix", json_of_float_opt summary.oldest
    ; "oldest_age_seconds", age_seconds_json ~now summary.oldest
    ; "pending_oldest_arrived_at_unix", json_of_float_opt summary.pending_oldest
    ; "pending_oldest_age_seconds", age_seconds_json ~now summary.pending_oldest
    ; "inflight_oldest_arrived_at_unix", json_of_float_opt summary.inflight_oldest
    ; "inflight_oldest_age_seconds", age_seconds_json ~now summary.inflight_oldest
    ; "transition_outbox_count", `Int summary.outbox_count
    ; "counts_complete", `Bool summary.counts_complete
    ; "read_errors", `List (List.map (fun message -> `String message) summary.read_errors)
    ]
;;

let compact_pending_count_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "pending_count", `Int summary.pending_count
    ; "oldest_age_seconds", age_seconds_json ~now summary.pending_oldest
    ]
;;

let compact_inflight_count_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "inflight_count", `Int summary.inflight_count
    ; "oldest_age_seconds", age_seconds_json ~now summary.inflight_oldest
    ]
;;

let fleet_summary_json ~now ~base_path =
  let discovery = discover_keeper_names_with_snapshots ~base_path in
  let summaries = List.map (keeper_summary ~base_path) discovery.keeper_names in
  let pending_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.pending_count)
      0
      summaries
  in
  let inflight_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.inflight_count)
      0
      summaries
  in
  let outbox_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.outbox_count)
      0
      summaries
  in
  let oldest =
    List.fold_left
      (fun oldest (summary : keeper_summary) -> min_float_opt oldest summary.oldest)
      None
      summaries
  in
  let read_errors =
    (match discovery.read_error with None -> [] | Some error -> [ `String error ])
    @ List.concat_map
        (fun (summary : keeper_summary) ->
           List.map (fun error -> `String error) summary.read_errors)
        summaries
  in
  let counts_complete =
    discovery.read_error = None
    && List.for_all (fun (summary : keeper_summary) -> summary.counts_complete) summaries
  in
  let projection_base_path =
    match Owner_lock.canonical_base_path base_path with
    | Ok path -> path
    | Error _ -> base_path
  in
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.fleet_summary.v1"
    ; "status", `String (if read_errors = [] then "ok" else "degraded")
    ; "operator_action_required", `Bool (read_errors <> [] || outbox_count > 0)
    ; "base_path", `String projection_base_path
    ; ( "keepers_runtime_dir"
      , `String (Common.keepers_runtime_dir_of_base ~base_path:projection_base_path) )
    ; "keeper_count", `Int (List.length discovery.keeper_names)
    ; "keeper_names", `List (List.map (fun name -> `String name) discovery.keeper_names)
    ; "pending_count", `Int pending_count
    ; "inflight_count", `Int inflight_count
    ; "total_count", `Int (pending_count + inflight_count)
    ; "transition_outbox_count", `Int outbox_count
    ; "counts_complete", `Bool counts_complete
    ; "oldest_arrived_at_unix", json_of_float_opt oldest
    ; "oldest_age_seconds", age_seconds_json ~now oldest
    ; ( "pending_by_keeper"
      , `List
          (summaries
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_pending_count_json ~now)) )
    ; ( "inflight_by_keeper"
      , `List
          (summaries
           |> List.filter (fun (summary : keeper_summary) -> summary.inflight_count > 0)
           |> List.map (compact_inflight_count_json ~now)) )
    ; "read_error_count", `Int (List.length read_errors)
    ; "read_errors", `List read_errors
    ; "keepers", `List (List.map (keeper_summary_json ~now) summaries)
    ]
;;
