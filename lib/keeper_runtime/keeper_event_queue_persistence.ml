module Owner_lock = Keeper_event_queue_owner_lock
module State = Keeper_event_queue_state

let state_change_observer : (unit -> unit) Atomic.t = Atomic.make ignore
let install_state_change_observer observer = Atomic.set state_change_observer observer

let notify_state_change_observer ~keeper_name =
  try (Atomic.get state_change_observer) () with
  | exn ->
    Log.Keeper.warn
      "event queue state-change observer failed keeper=%s: %s"
      keeper_name
      (Printexc.to_string exn)
;;

type owner_identity = Owner_lock.t
type owner_identity_error = Owner_lock.resolve_error

let resolve_owner_identity = Owner_lock.resolve
let owner_identity_error_to_string = Owner_lock.resolve_error_to_string
let owner_identity_equal = ( == )

let owner_identity_hash owner =
  Hashtbl.hash
    ( Owner_lock.base_path owner
    , Owner_lock.keeper_name owner |> Keeper_id.Keeper_name.to_string )
;;

let owner_identity_base_path = Owner_lock.base_path

let owner_identity_keeper_name owner =
  Owner_lock.keeper_name owner |> Keeper_id.Keeper_name.to_string
;;

type exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type accepted_cancellation = State.accepted_cancellation =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; reason : string
  }

type accepted_transfer = State.accepted_transfer =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; from_keeper : string
  ; to_keeper : string
  ; target_trace_id : Keeper_id.Trace_id.t
  }

type source_terminal_receipt = State.source_terminal_receipt =
  | Fusion_terminal of Keeper_event_queue.fusion_completion
  | Hitl_terminal of Keeper_event_queue.hitl_resolution
  | Turn_completed
  | Turn_attempt_terminal of { detail : string }

type accepted_source_terminal = State.accepted_source_terminal =
  { source : Keeper_event_queue.stimulus
  ; source_incarnation : int64
  ; operator_operation_id : string
  ; source_receipt : source_terminal_receipt
  }

type transition = State.transition =
  | Cancel_accepted of accepted_cancellation
  | Transfer_accepted of accepted_transfer
  | Ack_source_terminal of accepted_source_terminal

type transition_receipt = State.transition_receipt
type outbox_entry = State.outbox_entry

type transition_result =
  | Transition_applied of transition_receipt
  | Transition_already_applied of transition_receipt
  | Transition_committed_followup_failed of
      { receipt : transition_receipt
      ; stage : [ `Checkpoint | `Wal_compaction | `Projection ]
      ; detail : string
      }

type transfer_projection_result = State.transfer_projection_result =
  | Transfer_projected
  | Transfer_already_projected


(* v19 adds [attention_retentions] to every pending entry: a checkpoint-yield
   turn's retention of a Connector_attention wake is durable delivery bookkeeping
   (see [note_attention_retention_result]), so a restart must not reset it and
   v18 snapshots cannot supply it. The transition WAL carries a full pre-state,
   so both files hard-cut together; there is no compatibility decoder. *)
let snapshot_filename = "event-queue-v19.json"
let transition_wal_filename = "event-queue-transitions-v8.jsonl"

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

let transition_wal_path_of_owner owner =
  Filename.concat (keeper_runtime_dir_of_owner owner) transition_wal_filename
;;

let durable_state_exists_unlocked owner =
  Sys.file_exists (snapshot_path_of_owner owner)
  || Sys.file_exists (transition_wal_path_of_owner owner)
;;

let compact_wal_unlocked ~surface ~path owner =
  match
    Fs_compat.rewrite_private_file_durable_locked_result path (fun existing ->
      (if String.equal existing "" then None else Some ""), ())
  with
  | Ok () -> Ok ()
  | Error detail ->
    Error
      (Printf.sprintf
         "failed to compact checkpointed %s keeper=%s path=%s: %s"
         surface
         (keeper_name_of_owner owner)
         path
         detail)
;;

let compact_transition_wals_unlocked owner =
  compact_wal_unlocked
    ~surface:"transition WAL"
    ~path:(transition_wal_path_of_owner owner)
    owner
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

(* The decoded snapshot, against the file it was decoded from.

   The queue snapshot is rewritten whole rather than appended to, so the file
   identity and its size and mtime together say whether the bytes on disk are
   the bytes this state came from. Under a durable lock no writer can move
   them between the stat and the read.

   Measured 2026-09-05: an idle fleet of eighteen keepers re-read and
   re-parsed all 6.3 MB of these snapshots about 1.5 times a second, 282 MB
   in thirty seconds, and did the parse holding the owner's lock -- so every
   other reader of that keeper waited behind a JSON parse of up to a
   megabyte. The state does not change on most of those passes.

   Keyed by path rather than by owner: the path is what was read, and two
   owner values naming one file must not disagree about it. *)
type snapshot_cache_entry =
  { sce_stat : Unix.stats
  ; sce_state : State.t
  }

let snapshot_cache : (string, snapshot_cache_entry) Hashtbl.t = Hashtbl.create 32
let snapshot_cache_mutex = Stdlib.Mutex.create ()
let snapshot_cache_hit_counter = Atomic.make 0
let snapshot_cache_read_counter = Atomic.make 0

let same_snapshot_file (left : Unix.stats) (right : Unix.stats) =
  left.Unix.st_dev = right.Unix.st_dev
  && left.Unix.st_ino = right.Unix.st_ino
  && left.Unix.st_size = right.Unix.st_size
  && Float.equal left.Unix.st_mtime right.Unix.st_mtime
  && Float.equal left.Unix.st_ctime right.Unix.st_ctime
;;

let cached_snapshot path =
  match Unix.stat path with
  | exception (Unix.Unix_error _ | Sys_error _) -> None
  | stat ->
    Stdlib.Mutex.protect snapshot_cache_mutex (fun () ->
      match Hashtbl.find_opt snapshot_cache path with
      | Some entry when same_snapshot_file entry.sce_stat stat -> Some entry.sce_state
      | None | Some _ -> None)
;;

let remember_snapshot path state =
  (* Re-stat after the read: a write between the two would leave the cache
     describing bytes this decode never saw. *)
  match Unix.stat path with
  | exception (Unix.Unix_error _ | Sys_error _) -> ()
  | stat ->
    Stdlib.Mutex.protect snapshot_cache_mutex (fun () ->
      Hashtbl.replace snapshot_cache path { sce_stat = stat; sce_state = state })
;;

let forget_snapshot path =
  Stdlib.Mutex.protect snapshot_cache_mutex (fun () -> Hashtbl.remove snapshot_cache path)
;;

let save_state_unlocked_with ~strict_parent_sync owner state =
  let keeper_name = keeper_name_of_owner owner in
  let path = snapshot_path_of_owner owner in
  let save = if strict_parent_sync then save_json_atomic_strict else save_json_atomic in
  match save path (State.to_yojson state) with
  | Ok () ->
    (* The writer already holds the state it just wrote, so the next read is
       a hit rather than a re-parse of bytes this process produced. An atomic
       save renames a new file into place, so the stat recorded here is the
       one a reader will compare against. *)
    remember_snapshot path state;
    notify_state_change_observer ~keeper_name;
    Ok ()
  | Error message ->
    (* The file may be half-written, gone, or untouched -- unknown is not a
       state to answer future reads from. *)
    forget_snapshot path;
    Error
      (Printf.sprintf
         "failed to persist keeper=%s path=%s: %s"
         keeper_name
         path
         message)
;;

let save_state_unlocked = save_state_unlocked_with ~strict_parent_sync:false
let save_state_unlocked_strict = save_state_unlocked_with ~strict_parent_sync:true

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed
  | Incoherent_read

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

let snapshot_read_error_kind_to_string = function
  | Invalid_path -> "invalid_path"
  | Read_failed -> "read_failed"
  | Parse_failed -> "parse_failed"
  | Incoherent_read -> "incoherent_read"
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
  | Primary_absent
  | Primary_unreadable of string
      (** The file is there and this binary cannot decode it. Boot treats this
          exactly like [Primary_absent] — see [fail_open] below — but the health
          probe has to tell the two apart, because an unreadable queue and an
          empty queue look identical from the outside and only one of them
          means stimuli were lost. *)
  | Primary_current of State.t

let read_primary_current_unlocked owner =
  let path = snapshot_path_of_owner owner in
  Atomic.incr snapshot_cache_read_counter;
  match cached_snapshot path with
  | Some state ->
    Atomic.incr snapshot_cache_hit_counter;
    Ok (Primary_current state)
  | None ->
  match read_json_if_present path with
  | Error _ as error -> error
  | Ok None -> Ok Primary_absent
  | Ok (Some json) ->
    (* Fail open. A snapshot this binary cannot decode is an absent snapshot:
       the queue starts empty and the WAL replays on top, which is the same
       path a first boot takes. Refusing instead stopped the whole fleet three
       times on 2026-08-23, every time on a field or variant this binary had
       itself stopped writing, and every time with nothing pending. What is
       lost is the pending stimuli and the idempotence ledger in the
       unreadable file; the WARN below is the record of that loss. *)
    let fail_open detail =
      Log.Keeper.warn
        "event queue snapshot unreadable at %s, starting from an empty queue \
         (pending stimuli and the disposition ledger in it are lost): %s"
        path
        detail;
      Ok (Primary_unreadable detail)
    in
    (match schema_field json with
     | Error message -> fail_open message
     | Ok _ ->
       (match State.of_yojson json with
        | Ok state ->
          remember_snapshot path state;
          Ok (Primary_current state)
        (* An undecodable snapshot is not cached: it is answered by
           [fail_open] every time, which is where the WARN that records the
           loss is written. *)
        | Error message -> fail_open message))
;;

let read_primary_unlocked = read_primary_current_unlocked

let bump_revision state =
  if Int64.equal (State.revision state) Int64.max_int
  then Error "event queue revision exhausted"
  else Ok (State.with_revision (Int64.succ (State.revision state)) state)
;;

let transition_wal_schema = "masc.keeper_event_queue.transition.v8"

type transition_wal_row =
  { pre_state : State.t
  ; outbox_entry : State.outbox_entry
  }

let transition_wal_entry_to_line owner ~pre_state outbox_entry =
  `Assoc
    [ "schema", `String transition_wal_schema
    ; "base_path", `String (Owner_lock.base_path owner)
    ; "keeper_name", `String (keeper_name_of_owner owner)
    ; "pre_state", State.to_yojson pre_state
    ; "outbox_entry", State.outbox_entry_to_yojson outbox_entry
    ]
  |> Yojson.Safe.to_string
  |> fun row -> row ^ "\n"
;;

let validate_transition_wal_row pre_state outbox_entry =
  if State.transition_outbox pre_state <> []
  then Error "transition WAL pre-state already contains an outbox entry"
  else
    match State.replay_transition_outbox_entry outbox_entry pre_state with
    | Ok replayed when State.transition_outbox replayed = [ outbox_entry ] ->
      Ok { pre_state; outbox_entry }
    | Ok _ -> Error "transition WAL pre-state does not produce its exact outbox entry"
    | Error detail -> Error ("transition WAL pre-state is invalid: " ^ detail)
;;

let transition_wal_entry_of_json owner = function
  | `Assoc fields ->
    (match List.assoc_opt "schema" fields with
     | Some (`String schema) when String.equal schema transition_wal_schema ->
       (match List.sort (fun (left, _) (right, _) -> String.compare left right) fields with
        | [ ("base_path", `String base_path)
          ; ("keeper_name", `String keeper_name)
          ; ("outbox_entry", entry)
          ; ("pre_state", pre_state)
          ; ("schema", `String row_schema)
          ] ->
          if not (String.equal row_schema schema)
          then Error "transition WAL schema field changed during decode"
          else if
            not
              (String.equal base_path (Owner_lock.base_path owner)
               && String.equal keeper_name (keeper_name_of_owner owner))
          then Error "transition WAL row owner does not match its Keeper lane"
          else
            Result.bind (State.of_yojson pre_state) (fun pre_state ->
              Result.bind (State.outbox_entry_of_yojson entry) (fun outbox_entry ->
                validate_transition_wal_row pre_state outbox_entry))
        | _ -> Error "transition WAL row fields are not exact")
     | Some (`String schema) ->
       Error (Printf.sprintf "unsupported transition WAL schema: %s" schema)
     | Some _ | None -> Error "transition WAL schema must be a string")
  | _ -> Error "transition WAL row must be a JSON object"
;;

let replay_transition_wal_bytes ~wal_only owner state bytes =
  let row_is_already_projected (entry : State.outbox_entry) state =
    State.transition_outbox state = []
    && State.transition_receipt_is_projected entry.receipt state
  in
  let rec replay ~saw_row ~all_rows_already_projected state = function
    | [] | [ "" ] -> Ok (state, saw_row && all_rows_already_projected)
    | "" :: _ -> Error "transition WAL contains an empty row"
    | line :: rest ->
      (match
         try Ok (Yojson.Safe.from_string line) with
         | Yojson.Json_error detail -> Error detail
       with
       | Error detail -> Error ("invalid transition WAL JSON: " ^ detail)
       | Ok json ->
         (match transition_wal_entry_of_json owner json with
          | Error _ as error -> error
          | Ok { pre_state; outbox_entry = entry } ->
            let state = if wal_only && not saw_row then pre_state else state in
            let already_projected = row_is_already_projected entry state in
            let pre_state_matches =
              already_projected
              || State.transition_outbox state = [ entry ]
              || State.to_yojson state = State.to_yojson pre_state
            in
            if not pre_state_matches
            then Error "transition WAL pre-state conflicts with its durable snapshot"
            else (match State.replay_transition_outbox_entry entry state with
             | Error _ as error -> error
             | Ok state ->
               replay
                 ~saw_row:true
                 ~all_rows_already_projected:(all_rows_already_projected && already_projected)
                 state
                 rest)))
  in
  replay
    ~saw_row:false
    ~all_rows_already_projected:true
    state
    (String.split_on_char '\n' bytes)
;;

let read_and_replay_wal_unlocked ~wal_only ~path ~surface owner state =
  let replay_slice slice =
    match slice.Fs_compat.Private_jsonl_slice.bytes with
    | "" -> Ok (state, false)
    | bytes ->
       (match replay_transition_wal_bytes ~wal_only owner state bytes with
        | Error detail ->
          Error
            (reset_required_message
               ~path
               ~surface
               detail)
        | Ok replayed -> Ok replayed)
  in
  match Fs_compat.read_private_jsonl_slice_locked_result path ~from:0 with
  | Private_file_failed error ->
    Error
      (Printf.sprintf
         "failed to read %s keeper=%s path=%s: %s"
         surface
         (keeper_name_of_owner owner)
         path
         (Fs_compat.Private_jsonl_slice.error_to_string error))
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Printf.sprintf
         "failed to read %s keeper=%s path=%s: %s; descriptor cleanup failed: %s"
         surface
         (keeper_name_of_owner owner)
         path
         (Fs_compat.Private_jsonl_slice.error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | Private_file_succeeded slice -> replay_slice slice
  | Private_file_succeeded_with_cleanup_failure
      { value = slice; cleanup_failure } ->
    Log.Keeper.error
      "%s read succeeded with descriptor cleanup failure keeper=%s path=%s: %s"
      surface
      (keeper_name_of_owner owner)
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    replay_slice slice
;;

let replay_wal_unlocked ~wal_only ~path ~surface owner state =
  match read_and_replay_wal_unlocked ~wal_only ~path ~surface owner state with
  | Error _ as error -> error
  | Ok (replayed, all_rows_already_projected) ->
    if all_rows_already_projected
    then
      (* A projection checkpoint was durable before its WAL retirement.
         The exact row now proves only the same already-projected transition,
         so leaving it in place would block the next append (which rightly
         requires an empty WAL). This is the sole safe read-time compaction:
         any replay that reconstructs an outbox is still authoritative until
         [project_transition_outbox_result] records the reaction and retires
         it. *)
      compact_wal_unlocked ~surface ~path owner |> Result.map (fun () -> replayed)
    else Ok replayed
;;

let replay_wal_read_only_unlocked ~wal_only ~path ~surface owner state =
  read_and_replay_wal_unlocked ~wal_only ~path ~surface owner state |> Result.map fst
;;

let replay_transition_wal_unlocked ?(wal_only = false) owner state =
  replay_wal_unlocked
    ~wal_only
    ~path:(transition_wal_path_of_owner owner)
    ~surface:"transition WAL"
    owner
    state
;;

let replay_transition_wal_read_only_unlocked ?(wal_only = false) owner state =
  replay_wal_read_only_unlocked
    ~wal_only
    ~path:(transition_wal_path_of_owner owner)
    ~surface:"transition WAL"
    owner
    state
;;

let load_state_unlocked_with_primary_detail owner =
  let from_empty detail =
    Result.map
      (fun state -> state, detail)
      (replay_transition_wal_unlocked ~wal_only:true owner State.empty)
  in
  match read_primary_unlocked owner with
  | Error _ as error -> error
  | Ok (Primary_current state) ->
    Result.map (fun state -> state, None) (replay_transition_wal_unlocked owner state)
  | Ok Primary_absent -> from_empty None
  | Ok (Primary_unreadable detail) -> from_empty (Some detail)
;;

let load_state_unlocked owner =
  Result.map fst (load_state_unlocked_with_primary_detail owner)
;;

let load_state_result_with_primary_detail ~base_path ~keeper_name =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         load_state_unlocked_with_primary_detail owner)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue state load raised keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            (snapshot_path_of_owner owner)
            (Printexc.to_string exn)))
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


let read_state_read_only_unlocked ~require_existing owner =
  match read_primary_unlocked owner with
  | Error _ as error -> error
  | Ok (Primary_current state) ->
    replay_transition_wal_read_only_unlocked owner state
  | Ok (Primary_absent | Primary_unreadable _)
    when require_existing && not (durable_state_exists_unlocked owner) ->
    Error
      (Printf.sprintf
         "event queue durable state is missing keeper=%s snapshot_path=%s wal_path=%s"
         (keeper_name_of_owner owner)
         (snapshot_path_of_owner owner)
         (transition_wal_path_of_owner owner))
  | Ok (Primary_absent | Primary_unreadable _) ->
    replay_transition_wal_read_only_unlocked
      ~wal_only:true
      owner
      State.empty
;;

let validate_state_read_only_result_with ~require_existing ~base_path ~keeper_name =
  match resolve_owner ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok owner ->
    (try
       Owner_lock.with_durable_lock owner (fun () ->
         read_state_read_only_unlocked ~require_existing owner)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue read-only validation raised keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            (snapshot_path_of_owner owner)
            (Printexc.to_string exn)))
;;

type read_only_observation_error =
  | Observation_read_failed of string
  | Observation_changed of
      { keeper_name : string
      ; first_revision : int64
      ; second_revision : int64
      }

let read_only_observation_error_to_string = function
  | Observation_read_failed message -> message
  | Observation_changed { keeper_name; first_revision; second_revision } ->
    Printf.sprintf
      "event queue changed during lock-free observation keeper=%s first_revision=%Ld second_revision=%Ld"
      keeper_name
      first_revision
      second_revision
;;

let stable_read_only_observation ~keeper_name first second =
  if State.to_yojson first = State.to_yojson second
  then Ok second
  else
    Error
      (Observation_changed
         { keeper_name
         ; first_revision = State.revision first
         ; second_revision = State.revision second
         })
;;

let observe_state_read_only_typed_with ~between_samples ~base_path ~keeper_name =
  match resolve_owner ~base_path ~keeper_name with
  | Error message -> Error (Observation_read_failed message)
  | Ok owner ->
    (try
       Result.bind
         (read_state_read_only_unlocked ~require_existing:false owner
          |> Result.map_error (fun message -> Observation_read_failed message))
         (fun first ->
            between_samples ();
            Result.bind
              (read_state_read_only_unlocked ~require_existing:false owner
               |> Result.map_error (fun message -> Observation_read_failed message))
              (stable_read_only_observation ~keeper_name first))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Observation_read_failed
            (Printf.sprintf
               "event queue lock-free observation raised keeper=%s path=%s: %s"
               (keeper_name_of_owner owner)
               (snapshot_path_of_owner owner)
               (Printexc.to_string exn))))
;;

let validate_state_read_only_result ~base_path ~keeper_name =
  validate_state_read_only_result_with
    ~require_existing:false
    ~base_path
    ~keeper_name
;;

let validate_existing_state_read_only_result ~base_path ~keeper_name =
  validate_state_read_only_result_with
    ~require_existing:true
    ~base_path
    ~keeper_name
;;


let load_with_projection ~projection ~base_path ~keeper_name =
  load_state_result ~base_path ~keeper_name |> Result.map projection
;;

let load_result ~base_path ~keeper_name =
  load_with_projection ~projection:State.pending ~base_path ~keeper_name
;;

let load_pending_result ~base_path ~keeper_name =
  load_result ~base_path ~keeper_name
;;

type 'pending with_read_errors =
  { pending : 'pending
  ; read_errors : snapshot_read_error list
  }

type snapshot_with_errors = Keeper_event_queue.t with_read_errors
type selections_with_errors = State.pending_selection list with_read_errors

let diagnose_snapshot_read_error ~base_path ~keeper_name message =
  match resolve_owner ~base_path ~keeper_name with
  | Error invalid -> [ { kind = Invalid_path; path = None; message = invalid } ]
  | Ok owner ->
    let primary = snapshot_path_of_owner owner in
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
     | Some error -> [ error ]
     | None -> [ { kind = Parse_failed; path = None; message } ])
;;

let load_with_read_errors ~projection ~base_path ~keeper_name =
  match load_state_result_with_primary_detail ~base_path ~keeper_name with
  | Ok (state, None) -> { pending = projection state; read_errors = [] }
  | Ok (state, Some detail) ->
    (* The keeper booted on an empty queue and kept running; what it lost is
       still a read error, and the fleet summary is where an operator sees it. *)
    { pending = projection state
    ; read_errors = diagnose_snapshot_read_error ~base_path ~keeper_name detail
    }
  | Error message ->
    { pending = projection State.empty
    ; read_errors = diagnose_snapshot_read_error ~base_path ~keeper_name message
    }
;;

let load_snapshot_with_errors ~base_path ~keeper_name =
  load_with_read_errors ~projection:State.pending ~base_path ~keeper_name
;;

let load_selections_with_errors ~base_path ~keeper_name =
  load_with_read_errors ~projection:State.pending_selections ~base_path ~keeper_name
;;

let observe_snapshot_with_errors_with ~between_samples ~base_path ~keeper_name =
  match
    observe_state_read_only_typed_with
      ~between_samples
      ~base_path
      ~keeper_name
  with
  | Ok state -> { pending = State.pending state; read_errors = [] }
  | Error (Observation_read_failed message) ->
    { pending = Keeper_event_queue.empty
    ; read_errors = diagnose_snapshot_read_error ~base_path ~keeper_name message
    }
  | Error (Observation_changed _ as error) ->
    { pending = Keeper_event_queue.empty
    ; read_errors =
        [ { kind = Incoherent_read
          ; path = None
          ; message = read_only_observation_error_to_string error
          }
        ]
    }
;;

let observe_snapshot_with_errors ~base_path ~keeper_name =
  observe_snapshot_with_errors_with
    ~between_samples:(fun () -> ())
    ~base_path
    ~keeper_name
;;

module For_testing = struct
  let observe_snapshot_with_errors_with_interleave =
    observe_snapshot_with_errors_with
  ;;

  let snapshot_cache_reads () = Atomic.get snapshot_cache_read_counter
  let snapshot_cache_hits () = Atomic.get snapshot_cache_hit_counter

  let reset_snapshot_cache_for_testing () =
    Stdlib.Mutex.protect snapshot_cache_mutex (fun () -> Hashtbl.reset snapshot_cache);
    Atomic.set snapshot_cache_read_counter 0;
    Atomic.set snapshot_cache_hit_counter 0
  ;;
end

type durable_state_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

let discover_keeper_names_with_durable_state ~base_path =
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
                   let wal = Filename.concat keeper_dir transition_wal_filename in
                   if
                     not (Sys.file_exists keeper_dir && Sys.is_directory keeper_dir)
                     || not (Sys.file_exists primary || Sys.file_exists wal)
                   then names, errors
                   else
                     match Keeper_id.Keeper_name.of_string name with
                     | Ok keeper_name ->
                       Keeper_id.Keeper_name.to_string keeper_name :: names, errors
                     | Error reason ->
                       names,
                       Printf.sprintf
                         "invalid keeper name with durable event queue state: %s"
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
                "failed to discover durable event queue state under %s: %s"
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
             (* [load_state_unlocked] above replayed the transition WAL, so
                [next] already carries that transition's pending mutation and
                its transition outbox, and the snapshot just written persists
                both (schema v16). Retire the WAL here, paired with the revision
                bump that absorbed it. Leaving it behind is what latches the
                owner: the next load replays an already-absorbed row against
                the advanced revision, [commit_transition] rejects it on
                [source_incarnation], and no runtime path can clear it because the
                projector itself starts with [load_state_unlocked] (#26074). *)
             (match compact_transition_wals_unlocked owner with
              | Error _ as error -> error
              | Ok () ->
                after_commit (State.pending next);
                Ok value))))
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

let reprioritize_pending_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~selection
      ~urgency
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    State.reprioritize_pending ~selection ~urgency state)
;;

let defer_pending_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~selection
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    State.defer_pending ~selection state)
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

type 'authorization_error guarded_transfer_projection_result =
  | Transfer_projection_result of transfer_projection_result
  | First_projection_rejected of 'authorization_error

let project_accepted_transfer_guarded_result
      ~authorize_first_projection
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
      | Ok (next, result) when next == state ->
        after_commit (State.pending state);
        Ok (state, Transfer_projection_result result)
      | Ok (next, result) ->
        (match authorize_first_projection () with
         | Error error -> Ok (state, First_projection_rejected error)
         | Ok () -> Ok (next, Transfer_projection_result result)))
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

let peek_when_result ~base_path ~keeper_name ~now ~ready =
  match load_state_result ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok state -> Ok (State.peek_when ~now ~ready state)
;;

let select_when_result ~base_path ~keeper_name ~now ~ready =
  match load_state_result ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok state -> Ok (State.select_when ~now ~ready state)
;;

let pending_selections_result ~base_path ~keeper_name =
  match load_state_result ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok state -> Ok (State.pending_selections state)
;;

let validate_pending_selection_result ~base_path ~keeper_name ~selection =
  match load_state_result ~base_path ~keeper_name with
  | Error _ as error -> error
  | Ok state -> State.validate_pending_selection ~selection state
;;

let ack_pending_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~selection
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    match State.ack_pending ~selection state with
    | Error _ as error -> error
    | Ok state -> Ok (state, ()))
;;

let note_attention_retention_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~selection
      ()
  =
  commit_transform ~base_path ~keeper_name ~after_commit (fun state ->
    match State.note_attention_retention ~selection state with
    | Error _ as error -> error
    | Ok (state, payload) -> Ok (state, payload))
;;

let commit_transition_unlocked_with
      ~save_checkpoint
      ~compact_wal
      owner
      ~after_commit
      transition
      current
  =
  match transition current with
  | Error _ as error -> error
  | Ok (state, State.Transition_already_applied receipt) ->
    Ok (Transition_already_applied receipt, State.pending state)
  | Ok (state, State.Transition_applied receipt) ->
    (match State.transition_outbox state with
     | [ entry ] when State.transition_receipt_equal receipt entry.receipt ->
       (match bump_revision state with
     | Error _ as error -> error
     | Ok checkpoint ->
       let suffix = transition_wal_entry_to_line owner ~pre_state:current entry in
       let path = transition_wal_path_of_owner owner in
       let continue_after_commit () =
         let pending = State.pending checkpoint in
         match save_checkpoint owner checkpoint with
         | Error detail ->
           Ok
             ( Transition_committed_followup_failed
                 { receipt; stage = `Checkpoint; detail }
             , pending )
         | Ok () ->
           (match compact_wal owner with
            | Error detail ->
              Ok
                ( Transition_committed_followup_failed
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
                     ("pending projection cancelled after transition commit: "
                      ^ Printexc.to_string exn)
                 | exn -> Error (Printexc.to_string exn)
               with
               | Ok () -> Ok (Transition_applied receipt, pending)
               | Error detail ->
                 Ok
                   ( Transition_committed_followup_failed
                       { receipt; stage = `Projection; detail }
                   , pending )))
       in
       let continue_after_wal_commit () =
         notify_state_change_observer ~keeper_name:(keeper_name_of_owner owner);
         continue_after_commit ()
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
               "transition WAL commit failed keeper=%s path=%s: %s"
               (keeper_name_of_owner owner)
               path
               (Fs_compat.private_jsonl_append_error_to_string error))
        | Private_file_failed_with_cleanup_failure
            { error; cleanup_failure } ->
          Error
            (Printf.sprintf
               "transition WAL commit failed keeper=%s path=%s: %s; descriptor cleanup failed: %s"
               (keeper_name_of_owner owner)
               path
               (Fs_compat.private_jsonl_append_error_to_string error)
               (Fs_compat.private_jsonl_operation_failure_to_string
                  cleanup_failure))
        | Private_file_succeeded _committed_end_offset ->
          continue_after_wal_commit ()
        | Private_file_succeeded_with_cleanup_failure
            { value = _committed_end_offset; cleanup_failure } ->
          Log.Keeper.error
            "transition WAL commit succeeded with descriptor cleanup failure keeper=%s path=%s: %s"
            (keeper_name_of_owner owner)
            path
            (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
          continue_after_wal_commit ()))
     | [] | [ _ ] | _ :: _ :: _ ->
       Error "transition commit did not produce its canonical outbox entry")
;;

let commit_transition_unlocked =
  commit_transition_unlocked_with
    (* The transition WAL is the commit record. The projector checkpoints the
       post-transition pending state only after its reaction-ledger append
       succeeds. *)
    ~save_checkpoint:(fun _owner _state -> Ok ())
    ~compact_wal:(fun _owner -> Ok ())
;;

let cancel_pending_accepted_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~applied_at
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
           commit_transition_unlocked
             owner
             ~after_commit
             (State.cancel_pending_accepted
                ~applied_at
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
      ~applied_at
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
           commit_transition_unlocked
             owner
             ~after_commit
             (State.transfer_pending_accepted
                ~applied_at
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

let ack_pending_source_terminal_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~acked_at
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
           commit_transition_unlocked
             owner
             ~after_commit
             (State.ack_pending_source_terminal
                ~applied_at:acked_at
                ~source_terminal)
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue pending source-terminal ACK raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let terminalize_pending_turn_result
      ?(after_commit = fun _ -> ())
      ~base_path
      ~keeper_name
      ~transition
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
           commit_transition_unlocked
             owner
             ~after_commit
             transition
             state
           |> Result.map fst)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "event queue pending turn terminalization raised keeper=%s: %s"
            (keeper_name_of_owner owner)
            (Printexc.to_string exn)))
;;

let terminalize_pending_turn_attempt_result
      ?after_commit
      ~base_path
      ~keeper_name
      ~applied_at
      ~selection
      ~detail
      ()
  =
  terminalize_pending_turn_result
    ?after_commit
    ~base_path
    ~keeper_name
    ~transition:
      (State.terminalize_pending_turn_attempt
         ~applied_at
         ~selection
         ~detail)
    ()
;;

let terminalize_pending_turn_completed_result
      ?after_commit
      ~base_path
      ~keeper_name
      ~applied_at
      ~selection
      ()
  =
  terminalize_pending_turn_result
    ?after_commit
    ~base_path
    ~keeper_name
    ~transition:
      (State.terminalize_pending_turn_completed
         ~applied_at
         ~selection)
    ()
;;

let mark_transition_projected_result state ~transition_id =
  State.mark_transition_projected ~transition_id state
;;

let project_transition_outbox_result
      ~append_before_retire
      ~base_path
      ~keeper_name
  =
  let ( let* ) = Result.bind in
  let* owner = resolve_owner ~base_path ~keeper_name in
  try
    Owner_lock.with_durable_lock owner (fun () ->
      let* state = load_state_unlocked owner in
      match State.transition_outbox state with
      | [] -> Ok ()
      | [ entry ] ->
        let* () = append_before_retire entry in
        let* projected =
          mark_transition_projected_result
            state
            ~transition_id:entry.receipt.transition_id
        in
        let* projected = bump_revision projected in
        let* () = save_state_unlocked owner projected in
        compact_transition_wals_unlocked owner
      | entries ->
        Error
          (Printf.sprintf
             "event queue transition outbox cardinality invalid keeper=%s count=%d"
             keeper_name
             (List.length entries)))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "event queue transition projection raised keeper=%s: %s"
         keeper_name
         (Printexc.to_string exn))
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


let age_seconds_json ~now = function
  | None -> `Null
  | Some timestamp -> `Float (Float.max 0.0 (now -. timestamp))
;;

type owner_lifecycle =
  | Runnable
  | Recoverable
  | Retained_disabled
  | Paused_dead
  | Shutdown_fenced
  | Lifecycle_unknown of string

type keeper_summary =
  { keeper_name : string
  ; owner_lifecycle : owner_lifecycle
  ; pending_count : int
  ; pending_oldest : float option
  ; outbox_count : int
  ; counts_complete : bool
  ; read_errors : string list
  }

let keeper_summary ~base_path ~owner_lifecycle keeper_name =
  let owner_lifecycle = owner_lifecycle ~keeper_name in
  let lifecycle_read_errors () =
    match owner_lifecycle with
    | Runnable
    | Recoverable
    | Retained_disabled
    | Paused_dead
    | Shutdown_fenced -> []
    | Lifecycle_unknown detail ->
      [ Printf.sprintf "keeper lifecycle unavailable keeper=%s: %s" keeper_name detail ]
  in
  match load_state_result_with_primary_detail ~base_path ~keeper_name with
  | Ok (state, primary_detail) ->
    let pending = State.pending state in
    let pending_oldest = queue_oldest_arrived_at pending in
    let outbox = State.transition_outbox state in
    let primary_read_errors =
      match primary_detail with
      | None -> []
      | Some detail ->
        diagnose_snapshot_read_error ~base_path ~keeper_name detail
        |> List.map (fun error -> error.message)
    in
    let lifecycle_read_errors =
      if
        Keeper_event_queue.is_empty pending
        && outbox = []
        && primary_read_errors = []
      then []
      else lifecycle_read_errors ()
    in
    { keeper_name
    ; owner_lifecycle
    ; pending_count = Keeper_event_queue.length pending
    ; pending_oldest
    ; outbox_count = List.length outbox
    ; counts_complete = lifecycle_read_errors = [] && primary_read_errors = []
    ; read_errors = lifecycle_read_errors @ primary_read_errors
    }
  | Error message ->
    let lifecycle_read_errors = lifecycle_read_errors () in
    let read_errors =
      diagnose_snapshot_read_error ~base_path ~keeper_name message
      |> List.map (fun error -> error.message)
    in
    { keeper_name
    ; owner_lifecycle
    ; pending_count = 0
    ; pending_oldest = None
    ; outbox_count = 0
    ; counts_complete = false
    ; read_errors = lifecycle_read_errors @ read_errors
    }
;;

let owner_lifecycle_wire = function
  | Runnable -> "runnable"
  | Recoverable -> "recoverable"
  | Retained_disabled -> "retained_disabled"
  | Paused_dead -> "paused_dead"
  | Shutdown_fenced -> "shutdown_fenced"
  | Lifecycle_unknown _ -> "unclassified"
;;

let keeper_summary_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "owner_lifecycle", `String (owner_lifecycle_wire summary.owner_lifecycle)
    ; "pending_count", `Int summary.pending_count
    ; "total_count", `Int summary.pending_count
    ; "oldest_arrived_at_unix", Json_util.float_opt_to_json summary.pending_oldest
    ; "oldest_age_seconds", age_seconds_json ~now summary.pending_oldest
    ; "pending_oldest_arrived_at_unix", Json_util.float_opt_to_json summary.pending_oldest
    ; "pending_oldest_age_seconds", age_seconds_json ~now summary.pending_oldest
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

let compact_backlog_count_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "pending_count", `Int summary.pending_count
    ; "total_count", `Int summary.pending_count
    ; "oldest_age_seconds", age_seconds_json ~now summary.pending_oldest
    ]
;;

type backlog_summary =
  { pending_count : int
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
  let oldest =
    List.fold_left
      (fun oldest (summary : keeper_summary) ->
         min_float_opt oldest summary.pending_oldest)
      None
      keepers
  in
  { pending_count; oldest; keepers }
;;

let fleet_summary_json ~now ~base_path ~owner_lifecycle =
  let discovery = discover_keeper_names_with_durable_state ~base_path in
  let summaries =
    List.map (keeper_summary ~base_path ~owner_lifecycle) discovery.keeper_names
  in
  let pending_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.pending_count)
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
      (fun oldest (summary : keeper_summary) ->
         min_float_opt oldest summary.pending_oldest)
      None
      summaries
  in
  let runnable =
    backlog_summary
      ~matches:(function
        | Runnable -> true
        | Recoverable
        | Retained_disabled
        | Paused_dead
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let recoverable =
    backlog_summary
      ~matches:(function
        | Recoverable -> true
        | Runnable
        | Retained_disabled
        | Paused_dead
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let retained_disabled =
    backlog_summary
      ~matches:(function
        | Retained_disabled -> true
        | Runnable
        | Recoverable
        | Paused_dead
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let paused_dead =
    backlog_summary
      ~matches:(function
        | Paused_dead -> true
        | Runnable
        | Recoverable
        | Retained_disabled
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let shutdown_fenced =
    backlog_summary
      ~matches:(function
        | Shutdown_fenced -> true
        | Runnable
        | Recoverable
        | Retained_disabled
        | Paused_dead
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let unclassified =
    backlog_summary
      ~matches:(function
        | Lifecycle_unknown _ -> true
        | Runnable
        | Recoverable
        | Retained_disabled
        | Paused_dead
        | Shutdown_fenced -> false)
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
    || recoverable.pending_count > 0
    || retained_disabled.pending_count > 0
    || paused_dead.pending_count > 0
    || shutdown_fenced.pending_count > 0
  in
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.fleet_summary.v3"
    ; "status", `String (if operator_action_required then "degraded" else "ok")
    ; "operator_action_required", `Bool operator_action_required
    ; "base_path", `String projection_base_path
    ; ( "keepers_runtime_dir"
      , `String (Common.keepers_runtime_dir_of_base ~base_path:projection_base_path) )
    ; "keeper_count", `Int (List.length discovery.keeper_names)
    ; "keeper_names", `List (List.map (fun name -> `String name) discovery.keeper_names)
    ; "pending_count", `Int pending_count
    ; "total_count", `Int pending_count
    ; "transition_outbox_count", `Int outbox_count
    ; "counts_complete", `Bool counts_complete
    ; "oldest_arrived_at_unix", Json_util.float_opt_to_json oldest
    ; "oldest_age_seconds", age_seconds_json ~now oldest
    ; "runnable_backlog_count", `Int runnable.pending_count
    ; "runnable_oldest_arrived_at_unix", Json_util.float_opt_to_json runnable.oldest
    ; "runnable_oldest_age_seconds", age_seconds_json ~now runnable.oldest
    ; ( "runnable_by_keeper"
      , `List
          (runnable.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "recoverable_backlog_count", `Int recoverable.pending_count
    ; "recoverable_oldest_arrived_at_unix", Json_util.float_opt_to_json recoverable.oldest
    ; "recoverable_oldest_age_seconds", age_seconds_json ~now recoverable.oldest
    ; ( "recoverable_by_keeper"
      , `List
          (recoverable.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "retained_disabled_backlog_count", `Int retained_disabled.pending_count
    ; ( "retained_disabled_oldest_arrived_at_unix"
      , Json_util.float_opt_to_json retained_disabled.oldest )
    ; ( "retained_disabled_oldest_age_seconds"
      , age_seconds_json ~now retained_disabled.oldest )
    ; ( "retained_disabled_by_keeper"
      , `List
          (retained_disabled.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "paused_dead_backlog_count", `Int paused_dead.pending_count
    ; "paused_dead_oldest_arrived_at_unix", Json_util.float_opt_to_json paused_dead.oldest
    ; "paused_dead_oldest_age_seconds", age_seconds_json ~now paused_dead.oldest
    ; ( "paused_dead_by_keeper"
      , `List
          (paused_dead.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "shutdown_fenced_backlog_count", `Int shutdown_fenced.pending_count
    ; ( "shutdown_fenced_oldest_arrived_at_unix"
      , Json_util.float_opt_to_json shutdown_fenced.oldest )
    ; ( "shutdown_fenced_oldest_age_seconds"
      , age_seconds_json ~now shutdown_fenced.oldest )
    ; ( "shutdown_fenced_by_keeper"
      , `List
          (shutdown_fenced.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "unclassified_count", `Int unclassified.pending_count
    ; "unclassified_oldest_arrived_at_unix", Json_util.float_opt_to_json unclassified.oldest
    ; "unclassified_oldest_age_seconds", age_seconds_json ~now unclassified.oldest
    ; ( "unclassified_by_keeper"
      , `List
          (unclassified.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; ( "pending_by_keeper"
      , `List
          (summaries
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_pending_count_json ~now)) )
    ; "read_error_count", `Int (List.length read_errors)
    ; "read_errors", `List read_errors
    ; "keepers", `List (List.map (keeper_summary_json ~now) summaries)
    ]
;;
