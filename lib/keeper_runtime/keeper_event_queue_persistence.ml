module Owner_lock = Keeper_event_queue_owner_lock
module State = Keeper_event_queue_state

type lease_kind = State.lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason = State.requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Retry_after_pacing
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery

type escalation_reason = State.escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_failed

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

type settle_result = State.settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt

let lease_stimuli (lease : lease) = lease.stimuli
let lease_kind = State.lease_kind

let snapshot_filename = "event-queue.json"
let legacy_inflight_filename = "event-queue-inflight.json"

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

let legacy_inflight_path_of_owner owner =
  Filename.concat (keeper_runtime_dir_of_owner owner) legacy_inflight_filename
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
  | Primary_v1 of Keeper_event_queue.t
  | Primary_v2 of State.t

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
        | Ok state -> Ok (Primary_v2 state)
        | Error message -> Error (Printf.sprintf "%s: %s" path message))
     | Ok schema when String.equal schema "keeper.event_queue.v1" ->
       (match Keeper_event_queue.queue_of_yojson json with
        | Ok queue -> Ok (Primary_v1 queue)
        | Error message -> Error (Printf.sprintf "%s: %s" path message))
     | Ok schema ->
       Error (Printf.sprintf "%s: unsupported snapshot schema %s" path schema))
;;

let read_legacy_inflight_unlocked owner =
  let path = legacy_inflight_path_of_owner owner in
  match read_json_if_present path with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some json) ->
    (match Keeper_event_queue.queue_of_yojson json with
     | Ok queue -> Ok (Some queue)
     | Error message -> Error (Printf.sprintf "%s: %s" path message))
;;

let remove_legacy_inflight_unlocked owner =
  let path = legacy_inflight_path_of_owner owner in
  try
    if Sys.file_exists path then Sys.remove path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "v2 state committed but failed to remove legacy inflight input %s: %s"
         path
         (Printexc.to_string exn))
;;

let migrate_unlocked owner pending legacy_inflight =
  let state = State.with_pending pending State.empty in
  let migration =
    match legacy_inflight with
    | None -> Ok (state, None)
    | Some queue -> State.add_legacy_inflight (Keeper_event_queue.to_list queue) state
  in
  match migration with
  | Error _ as error -> error
  | Ok (state, _lease) ->
    let state =
      match State.recover_leases ~settled_at:(Time_compat.now ()) state with
      | Ok state -> Ok state
      | Error _ as error -> error
    in
    (match state with
     | Error _ as error -> error
     | Ok state ->
    (match save_state_unlocked owner state with
     | Error _ as error -> error
     | Ok () ->
       remove_legacy_inflight_unlocked owner |> Result.map (fun () -> state)))
;;

let load_state_unlocked owner =
  match read_primary_unlocked owner with
  | Error _ as error -> error
  | Ok (Primary_v2 state) ->
    let legacy_path = legacy_inflight_path_of_owner owner in
    (match read_json_if_present legacy_path with
     | Error _ as error -> error
     | Ok None -> Ok state
     | Ok (Some _) ->
       Error
         (Printf.sprintf
            "v2 event queue has forbidden legacy inflight residue: %s"
            legacy_path))
  | Ok Primary_missing ->
    (match read_legacy_inflight_unlocked owner with
     | Error _ as error -> error
     | Ok None -> Ok State.empty
     | Ok (Some legacy) ->
       migrate_unlocked owner Keeper_event_queue.empty (Some legacy))
  | Ok (Primary_v1 pending) ->
    (match read_legacy_inflight_unlocked owner with
     | Error _ as error -> error
     | Ok legacy -> migrate_unlocked owner pending legacy)
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
  match load_state_result ~base_path ~keeper_name with
  | Ok state -> projection state
  | Error message ->
    Log.Keeper.error
      "event_queue_snapshot: refusing unreadable state keeper=%s: %s"
      keeper_name
      message;
    Keeper_event_queue.empty
;;

let load ~base_path ~keeper_name =
  let queue = load_with_projection ~projection:replay_queue ~base_path ~keeper_name in
  if not (Keeper_event_queue.is_empty queue)
  then
    Log.Keeper.info
      "event_queue_snapshot: restored %s for keeper=%s"
      (Keeper_event_queue.summary queue)
      keeper_name;
  queue
;;

let load_pending ~base_path ~keeper_name =
  load_with_projection ~projection:State.pending ~base_path ~keeper_name
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
    let legacy = legacy_inflight_path_of_owner owner in
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
    (match inspect primary with
     | Some ({ kind = Read_failed; _ } as error) -> [ error ]
     | Some ({ kind = Parse_failed; _ } as primary_error) ->
       (match inspect legacy with
        | Some ({ kind = Read_failed; _ } as error) -> [ error ]
        | Some ({ kind = Parse_failed; _ } as error) -> [ error ]
        | Some { kind = Invalid_path; _ } -> [ primary_error ]
        | None -> [ primary_error ])
     | Some { kind = Invalid_path; _ } ->
       [ { kind = Invalid_path; path = None; message } ]
     | None ->
       (match inspect legacy with
        | Some error -> [ error ]
        | None -> [ { kind = Parse_failed; path = None; message } ]))
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
                   let legacy = Filename.concat keeper_dir legacy_inflight_filename in
                   if
                     not (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir)
                     || not (Sys.file_exists primary || Sys.file_exists legacy)
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

let bump_revision state =
  if Int64.equal (State.revision state) Int64.max_int
  then Error "event queue revision exhausted"
  else Ok (State.with_revision (Int64.succ (State.revision state)) state)
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

let settle_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~settled_at
      ~lease
      ~settlement
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    State.settle ~settled_at ~lease ~settlement state)
;;

let recover_leases_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~settled_at
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    match State.recover_leases ~settled_at state with
    | Error _ as error -> error
    | Ok state -> Ok (state, ()))
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

let keeper_summary_json ~now ~base_path keeper_name =
  let snapshot = load_snapshot_pair_with_errors ~base_path ~keeper_name in
  let pending_count = Keeper_event_queue.length snapshot.pending in
  let inflight_count = Keeper_event_queue.length snapshot.inflight in
  let pending_oldest = queue_oldest_arrived_at snapshot.pending in
  let inflight_oldest = queue_oldest_arrived_at snapshot.inflight in
  let oldest = min_float_opt pending_oldest inflight_oldest in
  let state = load_state_result ~base_path ~keeper_name in
  let outbox_count, unprojected_outbox_count =
    match state with
    | Error _ -> 0, 0
    | Ok state ->
      let outbox = State.transition_outbox state in
      ( List.length outbox
      , List.fold_left
          (fun count (entry : outbox_entry) ->
             if entry.projected_to_reaction_ledger then count else count + 1)
          0
          outbox )
  in
  let read_errors = List.map (fun error -> error.message) snapshot.read_errors in
  `Assoc
    [ "keeper_name", `String keeper_name
    ; "pending_count", `Int pending_count
    ; "inflight_count", `Int inflight_count
    ; "total_count", `Int (pending_count + inflight_count)
    ; "oldest_arrived_at_unix", json_of_float_opt oldest
    ; "oldest_age_seconds", age_seconds_json ~now oldest
    ; "pending_oldest_arrived_at_unix", json_of_float_opt pending_oldest
    ; "pending_oldest_age_seconds", age_seconds_json ~now pending_oldest
    ; "inflight_oldest_arrived_at_unix", json_of_float_opt inflight_oldest
    ; "inflight_oldest_age_seconds", age_seconds_json ~now inflight_oldest
    ; "transition_outbox_count", `Int outbox_count
    ; "unprojected_transition_outbox_count", `Int unprojected_outbox_count
    ; "read_errors", `List (List.map (fun message -> `String message) read_errors)
    ]
;;

let int_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`Int value) -> value
     | _ -> 0)
  | _ -> 0
;;

let float_option_field name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`Float value) -> Some value
     | Some (`Int value) -> Some (float_of_int value)
     | _ -> None)
  | _ -> None
;;

let list_field_json name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`List values) -> values
     | _ -> [])
  | _ -> []
;;

let fleet_summary_json ~now ~base_path =
  let discovery = discover_keeper_names_with_snapshots ~base_path in
  let keepers =
    List.map (keeper_summary_json ~now ~base_path) discovery.keeper_names
  in
  let pending_count =
    List.fold_left (fun total json -> total + int_field "pending_count" json) 0 keepers
  in
  let inflight_count =
    List.fold_left (fun total json -> total + int_field "inflight_count" json) 0 keepers
  in
  let outbox_count =
    List.fold_left
      (fun total json -> total + int_field "transition_outbox_count" json)
      0
      keepers
  in
  let unprojected_outbox_count =
    List.fold_left
      (fun total json -> total + int_field "unprojected_transition_outbox_count" json)
      0
      keepers
  in
  let oldest =
    List.fold_left
      (fun oldest json ->
         min_float_opt oldest (float_option_field "oldest_arrived_at_unix" json))
      None
      keepers
  in
  let read_errors =
    (match discovery.read_error with None -> [] | Some error -> [ `String error ])
    @ List.concat_map (list_field_json "read_errors") keepers
  in
  let keepers_with field =
    List.filter (fun json -> int_field field json > 0) keepers
  in
  let compact_count field json =
    match json with
    | `Assoc fields ->
      let keeper_name = Option.value ~default:`Null (List.assoc_opt "keeper_name" fields) in
      let count = Option.value ~default:(`Int 0) (List.assoc_opt field fields) in
      let oldest_age =
        let age_field =
          if String.equal field "pending_count"
          then "pending_oldest_age_seconds"
          else "inflight_oldest_age_seconds"
        in
        Option.value ~default:`Null (List.assoc_opt age_field fields)
      in
      `Assoc [ "keeper_name", keeper_name; field, count; "oldest_age_seconds", oldest_age ]
    | _ -> `Assoc []
  in
  let projection_base_path =
    match Owner_lock.canonical_base_path base_path with
    | Ok path -> path
    | Error _ -> base_path
  in
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.fleet_summary.v1"
    ; "status", `String (if read_errors = [] then "ok" else "degraded")
    ; "operator_action_required", `Bool (read_errors <> [] || unprojected_outbox_count > 0)
    ; "base_path", `String projection_base_path
    ; ( "keepers_runtime_dir"
      , `String (Common.keepers_runtime_dir_of_base ~base_path:projection_base_path) )
    ; "keeper_count", `Int (List.length discovery.keeper_names)
    ; "keeper_names", `List (List.map (fun name -> `String name) discovery.keeper_names)
    ; "pending_count", `Int pending_count
    ; "inflight_count", `Int inflight_count
    ; "total_count", `Int (pending_count + inflight_count)
    ; "transition_outbox_count", `Int outbox_count
    ; "unprojected_transition_outbox_count", `Int unprojected_outbox_count
    ; "oldest_arrived_at_unix", json_of_float_opt oldest
    ; "oldest_age_seconds", age_seconds_json ~now oldest
    ; ( "pending_by_keeper"
      , `List (List.map (compact_count "pending_count") (keepers_with "pending_count")) )
    ; ( "inflight_by_keeper"
      , `List (List.map (compact_count "inflight_count") (keepers_with "inflight_count")) )
    ; "read_error_count", `Int (List.length read_errors)
    ; "read_errors", `List read_errors
    ; "keepers", `List keepers
    ]
;;
