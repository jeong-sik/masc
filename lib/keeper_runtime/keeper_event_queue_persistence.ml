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
      ; stage : [ `Checkpoint | `Wal_compaction ]
      ; detail : string
      }

let lease_stimuli (lease : lease) = lease.stimuli
let lease_kind = State.lease_kind
let lease_sequence (lease : lease) = lease.sequence

let snapshot_filename = "event-queue-v4.json"
let settlement_wal_filename = "event-queue-v4-settlements.jsonl"

(* These names identify the retired epoch only. They are never passed to a
   queue decoder, WAL replay, writer, rename, or deletion path. Observation
   reports their raw presence so an operator can decide what to do with the
   quarantined bytes without turning them back into queue authority. *)
let retired_snapshot_filename = "event-queue.json"
let retired_settlement_wal_filename = "event-queue-settlements.jsonl"
let retired_inflight_filename = "event-queue-inflight.json"
let reaction_coordination_lock_filename = "event-queue-reaction-coordination.lock"

let before_reaction_coordination_lock_hook = Atomic.make (fun () -> ())

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

let retired_epoch_paths_of_owner owner =
  let runtime_dir = keeper_runtime_dir_of_owner owner in
  [ Filename.concat runtime_dir retired_snapshot_filename
  ; Filename.concat runtime_dir retired_settlement_wal_filename
  ; Filename.concat runtime_dir retired_inflight_filename
  ]
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
  match State.validate state with
  | Error detail ->
    Error
      (Printf.sprintf
         "refused invalid keeper event queue state keeper=%s path=%s: %s"
         keeper_name
         path
         detail)
  | Ok () ->
    (match
       save_json_atomic
         path
         (State.to_yojson
            ~owner_base_path:(Owner_lock.base_path owner)
            ~keeper_name
            state)
     with
     | Ok () -> Ok ()
     | Error message ->
       Error
         (Printf.sprintf
            "failed to persist keeper=%s path=%s: %s"
            keeper_name
            path
            message))
;;

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Retired_epoch_residue

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

let snapshot_read_error_kind_to_string = function
  | Invalid_path -> "invalid_path"
  | Read_failed -> "read_failed"
  | Parse_failed -> "parse_failed"
  | Retired_epoch_residue -> "retired_epoch_residue"
;;

let snapshot_read_error_to_yojson error =
  `Assoc
    [ "kind", `String (snapshot_read_error_kind_to_string error.kind)
    ; ( "path"
      , match error.path with
        | None -> `Null
        | Some path -> `String path )
    ; "message", `String error.message
    ; "operator_action_required", `Bool true
    ]
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
       (match
          State.of_yojson
            ~expected_owner_base_path:(Owner_lock.base_path owner)
            ~expected_keeper_name:(keeper_name_of_owner owner)
            json
        with
        | Ok state -> Ok (Primary_current state)
        | Error message -> Error (Printf.sprintf "%s: %s" path message))
     | Ok schema ->
       Error (Printf.sprintf "%s: unsupported snapshot schema %s" path schema))
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

let replay_settlement_wal_bytes_with_count owner state bytes =
  let rec replay state row_count = function
    | [] | [ "" ] -> Ok (state, row_count)
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
             | Ok state -> replay state (row_count + 1) rest)))
  in
  replay state 0 (String.split_on_char '\n' bytes)
;;

let replay_settlement_wal_bytes owner state bytes =
  replay_settlement_wal_bytes_with_count owner state bytes |> Result.map fst
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
  match read_primary_unlocked owner with
  | Error _ as error -> error
  | Ok (Primary_current state) -> replay_settlement_wal_unlocked owner state
  | Ok Primary_missing -> replay_settlement_wal_unlocked owner State.empty
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

let with_reaction_coordination_lock_result ~base_path ~keeper_name f =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    let runtime_dir = keeper_runtime_dir_of_owner owner in
    (match
       try
         Fs_compat.mkdir_p runtime_dir;
         Ok ()
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn -> Error (Printexc.to_string exn)
     with
     | Error detail ->
       Error
         (Printf.sprintf
            "failed to prepare event queue reaction coordination lock keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            runtime_dir
            detail)
     | Ok () ->
       let lock_path = Filename.concat runtime_dir reaction_coordination_lock_filename in
       Atomic.get before_reaction_coordination_lock_hook ();
       (match File_lock_eio.with_durable_lock ~lock_path f with
        | Ok value -> Ok value
        | Error error ->
          Error
            (Printf.sprintf
               "event queue reaction coordination lock failed keeper=%s: %s"
               (keeper_name_of_owner owner)
               (File_lock_eio.durable_lock_error_to_string error))))
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

let load_pending_result ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map State.pending
;;

type snapshot_source_generation =
  { snapshot_present : bool
  ; snapshot_revision : int64
  ; observed_revision : int64
  ; settlement_wal_end_offset : int
  ; settlement_wal_row_count : int
  }

type snapshot_observation =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  ; transition_outbox_count : int
  ; source_generation : snapshot_source_generation option
  ; read_errors : snapshot_read_error list
  }

let snapshot_source_generation_to_yojson generation =
  `Assoc
    [ "snapshot_present", `Bool generation.snapshot_present
    ; "snapshot_revision", `String (Int64.to_string generation.snapshot_revision)
    ; "observed_revision", `String (Int64.to_string generation.observed_revision)
    ; "settlement_wal_end_offset", `Int generation.settlement_wal_end_offset
    ; "settlement_wal_row_count", `Int generation.settlement_wal_row_count
    ]
;;

let snapshot_read_error kind ?path message = { kind; path; message }
;;

let read_primary_for_observation_unlocked owner =
  let path = snapshot_path_of_owner owner in
  try
    if not (Sys.file_exists path)
    then Ok (false, State.empty)
    else
      match Safe_ops.read_file_safe path with
      | Error message -> Error (snapshot_read_error Read_failed ~path message)
      | Ok bytes ->
        (match Safe_ops.parse_json_safe ~context:path bytes with
         | Error message -> Error (snapshot_read_error Parse_failed ~path message)
         | Ok json ->
           (match schema_field json with
            | Error message ->
              Error (snapshot_read_error Parse_failed ~path message)
            | Ok schema when String.equal schema State.schema ->
              (match
                 State.of_yojson
                   ~expected_owner_base_path:(Owner_lock.base_path owner)
                   ~expected_keeper_name:(keeper_name_of_owner owner)
                   json
               with
               | Ok state -> Ok (true, state)
               | Error message ->
                 Error (snapshot_read_error Parse_failed ~path message))
            | Ok schema ->
              Error
                (snapshot_read_error
                   Parse_failed
                   ~path
                   (Printf.sprintf "unsupported snapshot schema %s" schema))))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (snapshot_read_error Read_failed ~path (Printexc.to_string exn))
;;

let retired_epoch_residue_for_path path =
  try
    let _retired_path_stats = Unix.lstat path in
    Some
      (snapshot_read_error
         Retired_epoch_residue
         ~path
         "retired non-authoritative event queue epoch residue requires operator disposition; it was not decoded or used")
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> None
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Some
      (snapshot_read_error Read_failed ~path (Printexc.to_string exn))
;;

let retired_epoch_residue_errors owner =
  retired_epoch_paths_of_owner owner
  |> List.filter_map retired_epoch_residue_for_path
;;

let replay_settlement_wal_for_observation_unlocked owner state =
  let path = settlement_wal_path_of_owner owner in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Error error ->
    Error
      (snapshot_read_error
         Read_failed
         ~path
         (Fs_compat.Private_jsonl_slice.error_to_string error))
  | Ok slice when String.equal slice.bytes "" ->
    Ok (state, slice.end_offset, 0)
  | Ok slice ->
    (match replay_settlement_wal_bytes_with_count owner state slice.bytes with
     | Error message -> Error (snapshot_read_error Parse_failed ~path message)
     | Ok (replayed, row_count) ->
       (match bump_revision replayed with
        | Error message -> Error (snapshot_read_error Parse_failed ~path message)
        | Ok replayed -> Ok (replayed, slice.end_offset, row_count)))
;;

let empty_snapshot_observation read_errors =
  { pending = Keeper_event_queue.empty
  ; inflight = Keeper_event_queue.empty
  ; transition_outbox_count = 0
  ; source_generation = None
  ; read_errors
  }
;;

let observe_snapshot ~base_path ~keeper_name =
  match resolve_owner ~base_path ~keeper_name with
  | Error error ->
    empty_snapshot_observation
      [ snapshot_read_error Invalid_path error ]
  | Ok owner ->
    let retired_epoch_read_errors = retired_epoch_residue_errors owner in
    (match
       try
         Owner_lock.with_lock owner (fun () ->
           match read_primary_for_observation_unlocked owner with
           | Error error -> Error error
           | Ok (snapshot_present, snapshot_state) ->
             let snapshot_revision = State.revision snapshot_state in
             (match
                replay_settlement_wal_for_observation_unlocked
                  owner
                  snapshot_state
              with
              | Error error -> Error error
              | Ok (observed_state, settlement_wal_end_offset, settlement_wal_row_count) ->
                Ok
                  ( observed_state
                  , { snapshot_present
                    ; snapshot_revision
                    ; observed_revision = State.revision observed_state
                    ; settlement_wal_end_offset
                    ; settlement_wal_row_count
                    } )))
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Error
           (snapshot_read_error
              Read_failed
              ~path:(snapshot_path_of_owner owner)
              (Printexc.to_string exn))
     with
     | Error error ->
       empty_snapshot_observation (error :: retired_epoch_read_errors)
     | Ok (state, source_generation) ->
       { pending = State.pending state
       ; inflight = inflight_queue state
       ; transition_outbox_count = List.length (State.transition_outbox state)
       ; source_generation = Some source_generation
       ; read_errors = retired_epoch_read_errors
       })
;;

type snapshot_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

let queue_epoch_filenames =
  [ snapshot_filename
  ; settlement_wal_filename
  ; retired_snapshot_filename
  ; retired_settlement_wal_filename
  ; retired_inflight_filename
  ]
;;

let inspect_queue_epoch_paths keeper_dir =
  List.fold_left
    (fun (present, errors) filename ->
       let path = Filename.concat keeper_dir filename in
       try
         let _queue_epoch_path_stats = Unix.lstat path in
         true, errors
       with
       | Unix.Unix_error (Unix.ENOENT, _, _) -> present, errors
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         ( present
         , Printf.sprintf
             "failed to inspect durable event queue epoch path %s: %s"
             path
             (Printexc.to_string exn)
           :: errors ))
    (false, [])
    queue_epoch_filenames
;;

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
                   if
                     not (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir)
                   then names, errors
                   else
                     let epoch_present, inspection_errors =
                       inspect_queue_epoch_paths keeper_dir
                     in
                     let errors = List.rev_append inspection_errors errors in
                     if not epoch_present
                     then names, errors
                     else
                       match Keeper_id.Keeper_name.of_string name with
                       | Ok keeper_name ->
                         Keeper_id.Keeper_name.to_string keeper_name :: names, errors
                       | Error reason ->
                         names,
                         Printf.sprintf
                           "invalid keeper name with durable event queue epoch evidence: %s"
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

let commit_transform_unlocked owner transform =
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
           | Ok () -> Ok value)))
;;

let commit_transform ~base_path ~keeper_name transform =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         commit_transform_unlocked owner transform)
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

let update_checked_result ~base_path ~keeper_name f =
  commit_transform
    ~base_path
    ~keeper_name
    (fun state ->
       match f (State.pending state) with
       | Error _ as error -> error
       | Ok pending -> Ok (State.with_pending pending state, ()))
;;

type enqueue_stimulus_result =
  | Enqueued of Keeper_event_queue.stimulus
  | Already_present of Keeper_event_queue.stimulus

let exact_stimulus_equal left right =
  Yojson.Safe.equal
    (Keeper_event_queue.stimulus_to_yojson left)
    (Keeper_event_queue.stimulus_to_yojson right)
;;

module Stimulus_identity_map = Map.Make (String)

let identity_digest_collision identity =
  Error
    (Printf.sprintf
       "event queue stimulus identity digest collision: %s"
       identity)
;;

let add_durable_stimulus_to_index index stimulus =
  match Keeper_event_queue.stimulus_identity_id_result stimulus with
  | Error detail ->
    Error ("event queue durable stimulus identity is invalid: " ^ detail)
  | Ok identity ->
    (match Stimulus_identity_map.find_opt identity index with
     | None -> Ok (Stimulus_identity_map.add identity stimulus index)
     | Some existing ->
       (match
          Keeper_event_queue.stimulus_identity_equal_result existing stimulus
        with
        | Error detail ->
          Error ("event queue durable stimulus identity is invalid: " ^ detail)
        | Ok false -> identity_digest_collision identity
        | Ok true when exact_stimulus_equal existing stimulus -> Ok index
        | Ok true ->
          Error
            (Printf.sprintf
               "event queue durable state contains conflicting values for stimulus identity %s"
               identity)))
;;

let add_durable_stimuli_to_index initial stimuli =
  let rec loop index = function
    | [] -> Ok index
    | stimulus :: rest ->
      (match add_durable_stimulus_to_index index stimulus with
       | Error _ as error -> error
       | Ok index -> loop index rest)
  in
  loop initial stimuli
;;

let durable_stimulus_index state =
  let groups =
    Keeper_event_queue.to_list (State.pending state)
    :: (List.map (fun (lease : lease) -> lease.stimuli) (State.leases state)
        @ List.map
            (fun (entry : outbox_entry) -> entry.stimuli)
            (State.transition_outbox state))
  in
  let rec loop index = function
    | [] -> Ok index
    | stimuli :: rest ->
      (match add_durable_stimuli_to_index index stimuli with
       | Error _ as error -> error
       | Ok index -> loop index rest)
  in
  loop Stimulus_identity_map.empty groups
;;

let validate_enqueue_stimuli ~context stimuli =
  let rec loop index = function
    | [] -> Ok ()
    | stimulus :: rest ->
      (match Keeper_event_queue.validate_stimulus stimulus with
       | Ok () -> loop (index + 1) rest
       | Error detail ->
         Error (Printf.sprintf "%s[%d] is invalid: %s" context index detail))
  in
  loop 0 stimuli
;;

let admit_stimuli_if_absent state stimuli =
  match durable_stimulus_index state with
  | Error _ as error -> error
  | Ok initial_index ->
    let rec loop index pending changed reversed = function
      | [] ->
        let state = if changed then State.with_pending pending state else state in
        Ok (state, List.rev reversed)
      | stimulus :: rest ->
        (match Keeper_event_queue.stimulus_identity_id_result stimulus with
         | Error detail ->
           Error ("event queue candidate identity is invalid: " ^ detail)
         | Ok identity ->
           (match Stimulus_identity_map.find_opt identity index with
            | None ->
              loop
                (Stimulus_identity_map.add identity stimulus index)
                (Keeper_event_queue.enqueue pending stimulus)
                true
                (Enqueued stimulus :: reversed)
                rest
            | Some existing ->
              (match
                 Keeper_event_queue.stimulus_identity_equal_result
                   existing
                   stimulus
               with
               | Error detail ->
                 Error ("event queue candidate identity is invalid: " ^ detail)
               | Ok false -> identity_digest_collision identity
               | Ok true ->
                 loop
                   index
                   pending
                   changed
                   (Already_present existing :: reversed)
                   rest)))
    in
    loop initial_index (State.pending state) false [] stimuli
;;

let enqueue_stimulus_if_absent_result ~base_path ~keeper_name stimulus
  =
  match
    validate_enqueue_stimuli
      ~context:"event queue enqueue stimulus"
      [ stimulus ]
  with
  | Error _ as error -> error
  | Ok () ->
    commit_transform ~base_path ~keeper_name (fun state ->
      match admit_stimuli_if_absent state [ stimulus ] with
      | Error _ as error -> error
      | Ok (state, [ outcome ]) -> Ok (state, outcome)
      | Ok (_state, []) | Ok (_state, _ :: _ :: _) ->
        Error "event queue single admission changed result cardinality")
;;

let enqueue_stimuli_if_absent_result ~base_path ~keeper_name stimuli
  =
  match
    validate_enqueue_stimuli
      ~context:"event queue enqueue batch stimulus"
      stimuli
  with
  | Error _ as error -> error
  | Ok () ->
    commit_transform ~base_path ~keeper_name (fun state ->
      admit_stimuli_if_absent state stimuli)
;;

let update_result ~base_path ~keeper_name f =
  update_checked_result ~base_path ~keeper_name (fun queue -> Ok (f queue))
;;

let claim_when_result ~base_path ~keeper_name ~claimed_at ~ready ()
  =
  commit_transform ~base_path ~keeper_name (fun state ->
    match State.claim_when ~claimed_at ~ready state with
    | Error _ as error -> error
    | Ok (state, lease) -> Ok (state, lease))
;;

let claim_board_result ~base_path ~keeper_name ~claimed_at ()
  =
  commit_transform ~base_path ~keeper_name (fun state ->
    match State.claim_board ~claimed_at state with
    | Error _ as error -> error
    | Ok (state, lease) -> Ok (state, lease))
;;

let commit_settlement_unlocked
      owner
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
              | Ok () -> Ok (Settled receipt, pending)))))
;;

let settle_result ~base_path ~keeper_name ~settled_at ~lease ~settlement ()
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

let prepare_registration_result ~base_path ~keeper_name ~settled_at ()
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
    (fun state ->
       match State.mark_transition_projected ~transition_id state with
       | Error _ as error -> error
       | Ok state -> Ok (state, ()))
;;

let drop_by_post_id ~base_path ~keeper_name ~post_id ()
  =
  commit_transform
    ~base_path
    ~keeper_name
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

let snapshot_read_error_to_string error =
  let kind = snapshot_read_error_kind_to_string error.kind in
  match error.path with
  | None -> Printf.sprintf "%s: %s" kind error.message
  | Some path -> Printf.sprintf "%s path=%s: %s" kind path error.message
;;

let keeper_summary ~base_path keeper_name =
  let snapshot = observe_snapshot ~base_path ~keeper_name in
  let pending_oldest = queue_oldest_arrived_at snapshot.pending in
  let inflight_oldest = queue_oldest_arrived_at snapshot.inflight in
  { keeper_name
  ; pending_count = Keeper_event_queue.length snapshot.pending
  ; inflight_count = Keeper_event_queue.length snapshot.inflight
  ; pending_oldest
  ; inflight_oldest
  ; oldest = min_float_opt pending_oldest inflight_oldest
  ; outbox_count = snapshot.transition_outbox_count
  ; counts_complete = Option.is_some snapshot.source_generation
  ; read_errors = List.map snapshot_read_error_to_string snapshot.read_errors
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

module For_testing = struct
  let with_before_reaction_coordination_lock_hook hook f =
    let previous = Atomic.exchange before_reaction_coordination_lock_hook hook in
    Fun.protect
      ~finally:(fun () -> Atomic.set before_reaction_coordination_lock_hook previous)
      f
  ;;
end
