module Owner_lock = Keeper_event_queue_owner_lock
module State = Keeper_event_queue_state

type lease_kind = State.lease_kind =
  | Single
  | Board_batch

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

type exact_execution_terminal_cause = State.exact_execution_terminal_cause =
  | Execution_failed_after_dispatch
  | Attempt_already_started
  | Execution_cancelled_after_dispatch
  | Execution_provenance_mismatch
  | Domain_invalid_output
  | Invalid_structural_evidence
  | Invalid_structural_source_after_dispatch
  | Commit_admission_unavailable
  | Lifecycle_transition_failed_after_dispatch
  | Checkpoint_source_changed
  | Checkpoint_persistence_failed
  | Terminal_persistence_failed

type exact_execution_terminal = State.exact_execution_terminal =
  { cause : exact_execution_terminal_cause
  ; slot_id : string
  ; call_id : string
  }

type exact_execution_lease_status = State.exact_execution_lease_status =
  | Dispatch_uncertain
  | Terminal_quarantined of exact_execution_terminal_cause

type exact_execution_binding = State.exact_execution_binding =
  { lease_id : string
  ; lease_sequence : int64
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; status : exact_execution_lease_status
  }

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type escalation_reason = State.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_boundary_failed of { detail : string }
  | Failure_judgment_external_input_requested of
      { judge_runtime_id : string
      ; rationale : string
      }
  | Compaction_exact_lane_unconfigured of { source : Keeper_checkpoint_ref.t }
  | Compaction_exact_output_terminal of
      { source : Keeper_checkpoint_ref.t
      ; terminal : exact_execution_terminal
      }
  | Compaction_retry_exhausted of
      { attempts : int
      ; detail : string
      }
  | Compaction_floor_exceeded of
      { attempts : int
      ; detail : string
      }
  | Transcript_corruption_requires_reset of { detail : string }

type no_compaction_reason = State.no_compaction_reason =
  | No_eligible_history
  | Invalid_structural_source
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Exact_lane_unconfigured
  | Exact_execution_terminal of exact_execution_terminal

type no_compaction = State.no_compaction =
  { source : Keeper_checkpoint_ref.t
  ; reason : no_compaction_reason
  }

type accepted_cancellation = State.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = State.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  }

type source_terminal_receipt = State.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Background_job_terminal of Keeper_event_queue.bg_job_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution

type accepted_source_terminal = State.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_revision : int64
  ; owner_nonce : int
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type settlement = State.settlement =
  | Ack
  | No_compaction of no_compaction
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Settle_from_source_terminal of accepted_source_terminal
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

type transfer_projection_result = State.transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected

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

let save_json_atomic_with ~strict_parent_sync path json =
  match
    try Ok (Fs_compat.mkdir_p (Filename.dirname path)) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok () ->
    let content =
      json |> Safe_ops.sanitize_json_utf8 |> Yojson.Safe.pretty_to_string
    in
    if strict_parent_sync
    then Fs_compat.save_file_atomic_strict path content
    else Fs_compat.save_file_atomic path content
;;

let save_json_atomic = save_json_atomic_with ~strict_parent_sync:false
let save_json_atomic_strict = save_json_atomic_with ~strict_parent_sync:true

let save_json_atomic_strict_staged path json =
  match
    try Ok (Fs_compat.mkdir_p (Filename.dirname path)) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error _ as error -> error
  | Ok () ->
    let content =
      json |> Safe_ops.sanitize_json_utf8 |> Yojson.Safe.pretty_to_string
    in
    (match Fs_compat.save_file_atomic_strict_staged path content with
     | Ok () -> Ok Fsync_completed
     | Error (failure : Fs_compat.atomic_replace_failure) ->
       let detail = Fs_compat.atomic_replace_failure_to_string failure in
       (match failure.stage with
        | Fs_compat.Before_rename ->
          (match failure.exception_ with
           | Eio.Cancel.Cancelled _ ->
             Printexc.raise_with_backtrace failure.exception_ failure.backtrace
           | _ -> Error detail)
        | Fs_compat.After_rename ->
          Ok (Visible_sync_unconfirmed detail)))
;;

let save_state_unlocked_with ~strict_parent_sync owner state =
  let keeper_name = keeper_name_of_owner owner in
  let path = snapshot_path_of_owner owner in
  let save = if strict_parent_sync then save_json_atomic_strict else save_json_atomic in
  match save path (State.to_yojson state) with
  | Ok () -> Ok ()
  | Error message ->
    Error
      (Printf.sprintf
         "failed to persist keeper=%s path=%s: %s"
         keeper_name
         path
         message)
;;

let save_state_unlocked = save_state_unlocked_with ~strict_parent_sync:false
let save_state_unlocked_strict = save_state_unlocked_with ~strict_parent_sync:true

let save_state_unlocked_strict_staged owner state =
  let keeper_name = keeper_name_of_owner owner in
  let path = snapshot_path_of_owner owner in
  match save_json_atomic_strict_staged path (State.to_yojson state) with
  | Ok outcome -> Ok outcome
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

let reset_required_message ~path ~surface detail =
  Printf.sprintf "%s at %s is incompatible (reset required): %s" surface path detail
;;

let read_json_if_present path =
  try
    if Sys.file_exists path
    then
      (match Safe_ops.read_file_safe path with
       | Error message ->
         Error (Printf.sprintf "failed to read %s: %s" path message)
       | Ok bytes ->
         (try Ok (Some (Yojson.Safe.from_string bytes)) with
          | Yojson.Json_error detail ->
            Error
              (reset_required_message
                 ~path
                 ~surface:"event queue snapshot"
                 ("invalid JSON: " ^ detail))))
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
     | Error message ->
       Error
         (reset_required_message
            ~path
            ~surface:"event queue snapshot"
            message)
     | Ok _ ->
       (match State.of_yojson json with
        | Ok state -> Ok (Primary_current state)
        | Error message ->
          Error
            (reset_required_message
               ~path
               ~surface:"event queue snapshot"
               message)))
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

let settlement_wal_entry_to_line owner entry =
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.settlement.v2"
    ; "base_path", `String (Owner_lock.base_path owner)
    ; "keeper_name", `String (keeper_name_of_owner owner)
    ; "outbox_entry", State.outbox_entry_to_yojson entry
    ]
  |> Yojson.Safe.to_string
  |> fun row -> row ^ "\n"
;;

let settlement_wal_entry_of_json owner = function
  | `Assoc fields ->
    (match List.assoc_opt "schema" fields with
     | Some (`String schema)
       when not (String.equal schema "masc.keeper_event_queue.settlement.v2") ->
       Error (Printf.sprintf "unsupported settlement WAL schema: %s" schema)
     | _ ->
       (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
        | [ ("base_path", `String base_path)
          ; ("keeper_name", `String keeper_name)
          ; ("outbox_entry", entry)
          ; ("schema", `String "masc.keeper_event_queue.settlement.v2")
          ] ->
          if
            not
              (String.equal base_path (Owner_lock.base_path owner)
               && String.equal keeper_name (keeper_name_of_owner owner))
          then Error "settlement WAL row owner does not match its Keeper lane"
          else State.outbox_entry_of_yojson entry
        | _ -> Error "settlement WAL row fields are not exact"))
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
         (match settlement_wal_entry_of_json owner json with
          | Error _ as error -> error
          | Ok entry ->
            (match State.replay_transition_outbox_entry entry state with
             | Error _ as error -> error
             | Ok state -> replay state rest)))
  in
  replay state (String.split_on_char '\n' bytes)
;;

let replay_settlement_wal_unlocked owner state =
  let path = settlement_wal_path_of_owner owner in
  let replay_slice slice =
    match slice.Fs_compat.Private_jsonl_slice.bytes with
    | "" -> Ok state
    | bytes ->
       (match replay_settlement_wal_bytes owner state bytes with
        | Error detail ->
          Error
            (reset_required_message
               ~path
               ~surface:"settlement WAL"
               detail)
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
  in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Private_file_failed error ->
    Error
      (Printf.sprintf
         "failed to read settlement WAL keeper=%s path=%s: %s"
         (keeper_name_of_owner owner)
         path
         (Fs_compat.Private_jsonl_slice.error_to_string error))
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Printf.sprintf
         "failed to read settlement WAL keeper=%s path=%s: %s; descriptor settlement failed: %s"
         (keeper_name_of_owner owner)
         path
         (Fs_compat.Private_jsonl_slice.error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | Private_file_succeeded slice -> replay_slice slice
  | Private_file_succeeded_with_cleanup_failure
      { value = slice; cleanup_failure } ->
    Log.Keeper.error
      "settlement WAL read succeeded with descriptor settlement failure keeper=%s path=%s: %s"
      (keeper_name_of_owner owner)
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    replay_slice slice
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

let exact_execution_binding_result ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map State.exact_execution_binding
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

let commit_transform_unlocked
      ?(strict_snapshot_durability = false)
      owner
      ~after_commit
      transform
  =
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
          let save_state =
            if strict_snapshot_durability
            then save_state_unlocked_strict
            else save_state_unlocked
          in
          (match save_state owner next with
           | Error _ as error -> error
           | Ok () ->
             after_commit (State.pending next);
             Ok value)))
;;

let commit_transform
      ?(strict_snapshot_durability = false)
      ~base_path
      ~keeper_name
      ~after_commit
      transform
  =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         commit_transform_unlocked
           ~strict_snapshot_durability
           owner
           ~after_commit
           transform)
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

let commit_exact_transform_unlocked owner ~after_commit transform =
  match load_state_unlocked owner with
  | Error _ as error -> error
  | Ok current ->
    (match transform current with
     | Error _ as error -> error
     | Ok (next, value) ->
       let next =
         if next == current then Ok next else bump_revision next
       in
       (match next with
        | Error _ as error -> error
        | Ok next ->
          (match save_state_unlocked_strict_staged owner next with
           | Error _ as error -> error
           | Ok outcome ->
             after_commit (State.pending next);
             Ok (value, outcome))))
;;

let commit_exact_transform ~base_path ~keeper_name ~after_commit transform =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         commit_exact_transform_unlocked owner ~after_commit transform)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue exact transaction raised keeper=%s path=%s: %s"
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

let project_accepted_transfer_result
      ~after_commit
      ~base_path
      ~keeper_name
      ~transfer
  =
  if not (String.equal transfer.to_keeper keeper_name)
  then Error "target transfer projection owner does not match the durable queue owner"
  else
    commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
      match State.project_accepted_transfer transfer state with
      | Error _ as error -> error
      | Ok (next, result) ->
        if next == state then after_commit (State.pending next);
        Ok (next, result))
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

let bind_exact_execution_result
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  =
  commit_exact_transform
    ~base_path
    ~keeper_name
    ~after_commit:(fun _ -> ())
    (fun state ->
       State.bind_exact_execution
         ~lease
         ~slot_id
         ~call_id
         ~plan_fingerprint
         ~request_body_sha256
         state
       |> Result.map (fun next -> next, ()))
  |> Result.map snd
;;

let release_exact_execution_before_dispatch_result
      ~base_path
      ~keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  =
  commit_exact_transform
    ~base_path
    ~keeper_name
    ~after_commit:(fun _ -> ())
    (fun state ->
       State.release_exact_execution_before_dispatch
         ~lease
         ~slot_id
         ~call_id
         ~plan_fingerprint
         ~request_body_sha256
         state
       |> Result.map (fun next -> next, ()))
  |> Result.map snd
;;

let quarantine_exact_execution_result
      ~base_path
      ~keeper_name
      ~lease
      ~terminal
      ~plan_fingerprint
      ~request_body_sha256
      ()
  =
  commit_exact_transform
    ~base_path
    ~keeper_name
    ~after_commit:(fun _ -> ())
    (fun state ->
       State.quarantine_exact_execution
         ~lease
         ~terminal
         ~plan_fingerprint
         ~request_body_sha256
         state
       |> Result.map (fun next -> next, ()))
  |> Result.map snd
;;

let commit_settlement_transition_unlocked owner ~after_commit transition current =
  match transition current with
  | Error _ as error -> error
  | Ok (state, State.Already_settled receipt) ->
    Ok (Already_settled receipt, State.pending state)
  | Ok (state, State.Settled receipt) ->
    (match State.transition_outbox state with
     | [ entry ] when State.transition_receipt_equal receipt entry.receipt ->
       (match bump_revision state with
     | Error _ as error -> error
     | Ok checkpoint ->
       let suffix = settlement_wal_entry_to_line owner entry in
       let path = settlement_wal_path_of_owner owner in
       let continue_after_commit () =
         let pending = State.pending checkpoint in
         match save_state_unlocked owner checkpoint with
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
                   , pending )))
       in
       (match
          Fs_compat.append_private_jsonl_durable_locked_at_end_offset_result
            path
            ~expected_end_offset:0
            suffix
        with
        | Private_file_failed error ->
          Error
            (Printf.sprintf
               "settlement WAL commit failed keeper=%s path=%s: %s"
               (keeper_name_of_owner owner)
               path
               (Fs_compat.private_jsonl_append_error_to_string error))
        | Private_file_failed_with_cleanup_failure
            { error; cleanup_failure } ->
          Error
            (Printf.sprintf
               "settlement WAL commit failed keeper=%s path=%s: %s; descriptor settlement failed: %s"
               (keeper_name_of_owner owner)
               path
               (Fs_compat.private_jsonl_append_error_to_string error)
               (Fs_compat.private_jsonl_operation_failure_to_string
                  cleanup_failure))
        | Private_file_succeeded _committed_end_offset -> continue_after_commit ()
        | Private_file_succeeded_with_cleanup_failure
            { value = _committed_end_offset; cleanup_failure } ->
          Log.Keeper.error
            "settlement WAL commit succeeded with descriptor settlement failure keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            path
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
          continue_after_commit ()))
     | [] | [ _ ] | _ :: _ :: _ ->
       Error "settlement transition did not produce its canonical outbox entry")
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
           commit_settlement_transition_unlocked
             owner
             ~after_commit
             (State.settle ~settled_at ~lease ~settlement)
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

let settle_exact_execution_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~settled_at
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
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
           commit_settlement_transition_unlocked
             owner
             ~after_commit
             (State.settle_exact_execution
                ~settled_at
                ~lease
                ~slot_id
                ~call_id
                ~plan_fingerprint
                ~request_body_sha256
                ~settlement)
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "exact execution settlement raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let cancel_accepted_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~current_owner_nonce
      ~settled_at
      ~lease
      ~cancellation
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
           commit_settlement_transition_unlocked
             owner
             ~after_commit
             (State.cancel_accepted
                ~current_owner_nonce
                ~settled_at
                ~lease
                ~cancellation)
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue accepted cancellation raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let cancel_pending_accepted_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~current_owner_nonce
      ~settled_at
      ~cancellation
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
           commit_settlement_transition_unlocked
             owner
             ~after_commit
             (State.cancel_pending_accepted
                ~current_owner_nonce
                ~settled_at
                ~cancellation)
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue pending accepted cancellation raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let transfer_pending_accepted_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~current_owner_nonce
      ~settled_at
      ~transfer
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
           commit_settlement_transition_unlocked
             owner
             ~after_commit
             (State.transfer_pending_accepted
                ~current_owner_nonce
                ~settled_at
                ~transfer)
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue pending accepted transfer raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let settle_pending_from_source_terminal_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~current_owner_nonce
      ~settled_at
      ~source_terminal
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
           commit_settlement_transition_unlocked
             owner
             ~after_commit
             (State.settle_pending_from_source_terminal
                ~current_owner_nonce
                ~settled_at
                ~source_terminal)
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue pending source-terminal settlement raised keeper=%s: %s"
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
                 commit_settlement_transition_unlocked
                   owner
                   ~after_commit
                   (State.settle
                      ~settled_at
                      ~lease
                      ~settlement:(Requeue Registration_recovery))
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

type owner_lifecycle =
  | Runnable
  | Paused_retained
  | Lifecycle_unknown of string

type keeper_summary =
  { keeper_name : string
  ; owner_lifecycle : owner_lifecycle
  ; pending_count : int
  ; inflight_count : int
  ; pending_oldest : float option
  ; inflight_oldest : float option
  ; oldest : float option
  ; outbox_count : int
  ; counts_complete : bool
  ; read_errors : string list
  }

let keeper_summary ~base_path ~owner_lifecycle keeper_name =
  let owner_lifecycle = owner_lifecycle ~keeper_name in
  let lifecycle_read_errors =
    match owner_lifecycle with
    | Runnable | Paused_retained -> []
    | Lifecycle_unknown detail ->
      [ Printf.sprintf "keeper lifecycle unavailable keeper=%s: %s" keeper_name detail ]
  in
  match load_state_result ~base_path ~keeper_name with
  | Ok state ->
    let pending = State.pending state in
    let inflight = inflight_queue state in
    let pending_oldest = queue_oldest_arrived_at pending in
    let inflight_oldest = queue_oldest_arrived_at inflight in
    let outbox = State.transition_outbox state in
    { keeper_name
    ; owner_lifecycle
    ; pending_count = Keeper_event_queue.length pending
    ; inflight_count = Keeper_event_queue.length inflight
    ; pending_oldest
    ; inflight_oldest
    ; oldest = min_float_opt pending_oldest inflight_oldest
    ; outbox_count = List.length outbox
    ; counts_complete = lifecycle_read_errors = []
    ; read_errors = lifecycle_read_errors
    }
  | Error message ->
    let read_errors =
      diagnose_snapshot_read_error ~base_path ~keeper_name message
      |> List.map (fun error -> error.message)
    in
    { keeper_name
    ; owner_lifecycle
    ; pending_count = 0
    ; inflight_count = 0
    ; pending_oldest = None
    ; inflight_oldest = None
    ; oldest = None
    ; outbox_count = 0
    ; counts_complete = false
    ; read_errors = lifecycle_read_errors @ read_errors
    }
;;

let owner_lifecycle_wire = function
  | Runnable -> "runnable"
  | Paused_retained -> "paused_retained"
  | Lifecycle_unknown _ -> "unclassified"
;;

let keeper_summary_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "owner_lifecycle", `String (owner_lifecycle_wire summary.owner_lifecycle)
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

let compact_backlog_count_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "pending_count", `Int summary.pending_count
    ; "inflight_count", `Int summary.inflight_count
    ; "total_count", `Int (summary.pending_count + summary.inflight_count)
    ; "oldest_age_seconds", age_seconds_json ~now summary.oldest
    ]
;;

type backlog_summary =
  { pending_count : int
  ; inflight_count : int
  ; oldest : float option
  ; keepers : keeper_summary list
  }

let backlog_summary ~matches summaries =
  let keepers = List.filter (fun (summary : keeper_summary) -> matches summary.owner_lifecycle) summaries in
  let pending_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.pending_count)
      0
      keepers
  in
  let inflight_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.inflight_count)
      0
      keepers
  in
  let oldest =
    List.fold_left
      (fun oldest (summary : keeper_summary) -> min_float_opt oldest summary.oldest)
      None
      keepers
  in
  { pending_count; inflight_count; oldest; keepers }
;;

let fleet_summary_json ~now ~base_path ~owner_lifecycle =
  let discovery = discover_keeper_names_with_snapshots ~base_path in
  let summaries =
    List.map (keeper_summary ~base_path ~owner_lifecycle) discovery.keeper_names
  in
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
  let runnable =
    backlog_summary
      ~matches:(function Runnable -> true | Paused_retained | Lifecycle_unknown _ -> false)
      summaries
  in
  let paused_retained =
    backlog_summary
      ~matches:(function Paused_retained -> true | Runnable | Lifecycle_unknown _ -> false)
      summaries
  in
  let unclassified =
    backlog_summary
      ~matches:(function Lifecycle_unknown _ -> true | Runnable | Paused_retained -> false)
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
  let operator_action_required =
    read_errors <> []
    || outbox_count > 0
    || paused_retained.pending_count + paused_retained.inflight_count > 0
  in
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.fleet_summary.v2"
    ; "status", `String (if operator_action_required then "degraded" else "ok")
    ; "operator_action_required", `Bool operator_action_required
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
    ; "runnable_pending_count", `Int runnable.pending_count
    ; "runnable_inflight_count", `Int runnable.inflight_count
    ; "runnable_backlog_count", `Int (runnable.pending_count + runnable.inflight_count)
    ; "runnable_oldest_arrived_at_unix", json_of_float_opt runnable.oldest
    ; "runnable_oldest_age_seconds", age_seconds_json ~now runnable.oldest
    ; ( "runnable_by_keeper"
      , `List
          (runnable.keepers
           |> List.filter (fun (summary : keeper_summary) ->
             summary.pending_count + summary.inflight_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "paused_retained_pending_count", `Int paused_retained.pending_count
    ; "paused_retained_inflight_count", `Int paused_retained.inflight_count
    ; ( "paused_retained_count"
      , `Int (paused_retained.pending_count + paused_retained.inflight_count) )
    ; ( "paused_retained_oldest_arrived_at_unix"
      , json_of_float_opt paused_retained.oldest )
    ; "paused_retained_oldest_age_seconds", age_seconds_json ~now paused_retained.oldest
    ; ( "paused_retained_by_keeper"
      , `List
          (paused_retained.keepers
           |> List.filter (fun (summary : keeper_summary) ->
             summary.pending_count + summary.inflight_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "unclassified_pending_count", `Int unclassified.pending_count
    ; "unclassified_inflight_count", `Int unclassified.inflight_count
    ; "unclassified_count", `Int (unclassified.pending_count + unclassified.inflight_count)
    ; "unclassified_oldest_arrived_at_unix", json_of_float_opt unclassified.oldest
    ; "unclassified_oldest_age_seconds", age_seconds_json ~now unclassified.oldest
    ; ( "unclassified_by_keeper"
      , `List
          (unclassified.keepers
           |> List.filter (fun (summary : keeper_summary) ->
             summary.pending_count + summary.inflight_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
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
