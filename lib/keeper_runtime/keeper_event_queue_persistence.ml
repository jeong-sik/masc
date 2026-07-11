(** Durable snapshot store for per-keeper Event Layer queues.

    The registry keeps the live queue in [registry_entry.event_queue]. This
    module mirrors the post-CAS queue snapshot to disk so a keeper restart can
    replay pending stimuli instead of resetting to [Keeper_event_queue.empty].

    Reads and writes over the pending/inflight snapshot pair are serialized with
    an Eio mutex in runtime fibers. Setup/tests that reach this module without
    an Eio context fall back to a Stdlib mutex. *)

let eio_write_mu = Eio.Mutex.create ()
let fallback_write_mu = Stdlib.Mutex.create ()

(* [eio_write_mu] is process-global, so a poisoned mutex blocks durable
   event-queue snapshots for EVERY keeper for the lifetime of the process
   (audit 2026-06-29). [Eio.Mutex.use_rw] poisons the mutex permanently if the
   critical section raises, so the failure must never cross the [use_rw]
   boundary: a non-cancellation exception is captured inside the critical
   section and re-raised — with its original backtrace — only after the lock is
   released, leaving the mutex usable for the next keeper. [Eio.Cancel.Cancelled]
   is re-raised in place so cancellation/shutdown is honoured and never swallowed
   (CancelledNeverAbsorbed). The external contract is unchanged: [with_write_lock]
   still returns [f ()] or re-raises its exception. *)
let with_write_lock : type a. (unit -> a) -> a =
 fun f ->
  let guarded () =
    match f () with
    | v -> Ok v
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  let outcome =
    match Eio_context.get_switch_opt () with
    | Some _ -> Eio.Mutex.use_rw ~protect:true eio_write_mu guarded
    | None -> Stdlib.Mutex.protect fallback_write_mu guarded
  in
  match outcome with
  | Ok v -> v
  | Error (exn, bt) -> Printexc.raise_with_backtrace exn bt

let valid_keeper_name name =
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  (not (String.equal name "")) && String.for_all valid_char name

let snapshot_filename = "event-queue.json"
let inflight_snapshot_filename = "event-queue-inflight.json"

(* [Fs_compat.mkdir_p] raises (Sys_error / Unix_error) on ENOSPC/EROFS/ENOTDIR
   instead of returning a result, so route it through the same [(unit, string)
   result] channel as the typed atomic writer. This keeps [save_json_atomic] total:
   it never raises for a disk failure, so the enclosing [with_write_lock]
   critical section returns normally and the shared mutex is not poisoned.
   [Eio.Cancel.Cancelled] is re-raised so cancellation is not flattened into a
   string error. *)
let save_json_atomic path json =
  match
    (try Ok (Fs_compat.mkdir_p (Filename.dirname path)) with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> Error (Printexc.to_string exn))
  with
  | Error _ as err -> err
  | Ok () ->
    let content =
      json
      |> Safe_ops.sanitize_json_utf8
      |> Yojson.Safe.pretty_to_string
    in
    let report = Fs_compat.save_file_atomic_eio path content in
    Fs_compat.Durable_mutation.fold_report report
      ~not_committed:(fun report ->
        Error (Fs_compat.Durable_mutation.report_to_string report))
      ~committed_not_durable:(fun report ->
        Log.Keeper.warn
          "event queue snapshot committed with sync debt path=%s detail=%s"
          path
          (Fs_compat.Durable_mutation.report_to_string report);
        Ok ())
      ~durable:(fun report ->
        (match report.diagnostics with
         | [] -> ()
         | _ ->
           Log.Keeper.warn
             "event queue snapshot durable with cleanup diagnostics path=%s detail=%s"
             path
             (Fs_compat.Durable_mutation.report_to_string report));
        Ok ())

let snapshot_path ~base_path ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         snapshot_filename)
  else Error (Printf.sprintf "invalid keeper name for event queue snapshot: %s" keeper_name)

let inflight_path ~base_path ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         inflight_snapshot_filename)
  else Error (Printf.sprintf "invalid keeper name for event queue inflight: %s" keeper_name)

type dir_state =
  | Missing
  | Directory
  | Not_directory

let dir_state path =
  try
    if not (Sys.file_exists path)
    then Ok Missing
    else if Sys.is_directory path
    then Ok Directory
    else Ok Not_directory
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "failed to inspect directory %s: %s" path (Printexc.to_string exn))

let file_exists_safe path =
  try Ok (Sys.file_exists path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "failed to inspect file %s: %s" path (Printexc.to_string exn))

type snapshot_discovery =
  { keeper_names : string list
  ; read_error : string option
  }

let discover_keeper_names_with_snapshots ~base_path =
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  match dir_state keepers_dir with
  | Error msg -> { keeper_names = []; read_error = Some msg }
  | Ok Missing -> { keeper_names = []; read_error = None }
  | Ok Not_directory ->
    { keeper_names = []
    ; read_error = Some (Printf.sprintf "keepers runtime path is not a directory: %s" keepers_dir)
    }
  | Ok Directory ->
    (match Safe_ops.list_dir_safe keepers_dir with
     | Error msg -> { keeper_names = []; read_error = Some msg }
     | Ok entries ->
       let names, errors =
         List.fold_left
           (fun (names, errors) name ->
              let keeper_dir = Filename.concat keepers_dir name in
              match dir_state keeper_dir with
              | Error msg -> names, msg :: errors
              | Ok Missing | Ok Not_directory -> names, errors
              | Ok Directory ->
                let pending_path = Filename.concat keeper_dir snapshot_filename in
                let inflight_path = Filename.concat keeper_dir inflight_snapshot_filename in
                (match file_exists_safe pending_path, file_exists_safe inflight_path with
                 | Error msg, _ | _, Error msg -> names, msg :: errors
                 | Ok false, Ok false -> names, errors
                 | Ok true, _ | _, Ok true ->
                   if valid_keeper_name name
                   then name :: names, errors
                   else
                     ( names
                     , Printf.sprintf
                         "invalid keeper name with durable event queue snapshot: %s"
                         name
                       :: errors )))
           ([], [])
           entries
       in
       { keeper_names = List.sort_uniq String.compare names
       ; read_error =
           (match List.rev errors with
            | [] -> None
            | errors -> Some (String.concat "; " errors))
       })

let rec queue_contains queue stimulus =
  match Keeper_event_queue.dequeue queue with
  | None -> false
  | Some (head, rest) ->
    Keeper_event_queue.stimulus_identity_equal head stimulus
    || queue_contains rest stimulus

let append_missing queue stimuli =
  List.fold_left
    (fun acc stimulus ->
       if queue_contains acc stimulus then acc else Keeper_event_queue.enqueue acc stimulus)
    queue
    stimuli

let prepend_missing queue stimuli =
  let missing =
    List.filter (fun stimulus -> not (queue_contains queue stimulus)) stimuli
  in
  Keeper_event_queue.prepend_list missing queue

let queue_of_list stimuli =
  List.fold_left Keeper_event_queue.enqueue Keeper_event_queue.empty stimuli

let remove_stimuli queue stimuli =
  match stimuli with
  | [] -> queue
  | _ ->
    let remove stimulus =
      List.exists
        (fun target -> Keeper_event_queue.stimulus_identity_equal target stimulus)
        stimuli
    in
    queue
    |> Keeper_event_queue.to_list
    |> List.filter (fun stimulus -> not (remove stimulus))
    |> queue_of_list

type snapshot_read_error_kind =
  | Invalid_path
  | Read_failed
  | Parse_failed

type snapshot_read_error =
  { kind : snapshot_read_error_kind
  ; path : string option
  ; message : string
  }

type snapshot_pair_with_errors =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  ; read_errors : snapshot_read_error list
  }

let snapshot_read_error_kind_to_string = function
  | Invalid_path -> "invalid_path"
  | Read_failed -> "read_failed"
  | Parse_failed -> "parse_failed"
;;

(* [log_restore] gates the "restored N pending" info line. It is a genuine
   restore signal only on the live hydration path ([load]); the operator
   health surfaces ([load_snapshot_pair*]) call this on every dashboard poll,
   where the same line is pure read-on-log noise (~1000 lines / 5000 in the
   2026-07-07 fleet log). Default off so only [load] announces a restore. *)
let load_from_path_with_errors ?(log_restore = false) ~keeper_name path =
  if not (Sys.file_exists path)
  then Keeper_event_queue.empty, []
  else (
    match Safe_ops.read_json_file_safe path with
    | Error msg ->
      Log.Keeper.warn
        "event_queue_snapshot: failed to read keeper=%s path=%s: %s"
        keeper_name
        path
        msg;
      ( Keeper_event_queue.empty
      , [ { kind = Read_failed; path = Some path; message = msg } ] )
    | Ok json ->
      (match Keeper_event_queue.queue_of_yojson json with
       | Error msg ->
         Log.Keeper.warn
           "event_queue_snapshot: failed to parse keeper=%s path=%s: %s"
           keeper_name
           path
           msg;
         ( Keeper_event_queue.empty
         , [ { kind = Parse_failed; path = Some path; message = msg } ] )
       | Ok queue ->
         let deduped = Keeper_event_queue.dedup_by_identity queue in
         let dropped =
           Keeper_event_queue.length queue - Keeper_event_queue.length deduped
         in
         if dropped > 0
         then
           Log.Keeper.warn
             "event_queue_snapshot: dropped %d duplicate stimulus identity rows for keeper=%s path=%s"
             dropped
             keeper_name
             path;
         if log_restore && not (Keeper_event_queue.is_empty deduped)
         then
           Log.Keeper.info
             "event_queue_snapshot: restored %s for keeper=%s"
             (Keeper_event_queue.summary deduped)
             keeper_name;
         deduped, []))
;;

let load_from_path ?(log_restore = false) ~keeper_name path =
  let queue, _read_errors = load_from_path_with_errors ~log_restore ~keeper_name path in
  queue
;;

type snapshot_pair =
  { pending : Keeper_event_queue.t
  ; inflight : Keeper_event_queue.t
  }

let empty_snapshot_pair =
  { pending = Keeper_event_queue.empty; inflight = Keeper_event_queue.empty }
;;

let empty_snapshot_pair_with_errors =
  { pending = Keeper_event_queue.empty
  ; inflight = Keeper_event_queue.empty
  ; read_errors = []
  }
;;

let load_snapshot_pair_unlocked ~log_restore ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    empty_snapshot_pair
  | Ok pending_path, Ok inflight_path ->
    let pending = load_from_path ~log_restore ~keeper_name pending_path in
    let inflight = load_from_path ~log_restore ~keeper_name inflight_path in
    { pending; inflight }
;;

let load_snapshot_pair_with_errors_unlocked ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    { empty_snapshot_pair_with_errors with
      read_errors = [ { kind = Invalid_path; path = None; message = msg } ]
    }
  | Ok pending_path, Ok inflight_path ->
    let pending, pending_errors = load_from_path_with_errors ~keeper_name pending_path in
    let inflight, inflight_errors = load_from_path_with_errors ~keeper_name inflight_path in
    { pending; inflight; read_errors = pending_errors @ inflight_errors }
;;

let load_unlocked ~base_path ~keeper_name =
  (* The live hydration path: announce the restore once. *)
  let pair = load_snapshot_pair_unlocked ~log_restore:true ~base_path ~keeper_name in
  prepend_missing pair.pending (Keeper_event_queue.to_list pair.inflight)
;;

let load_snapshot_pair ~base_path ~keeper_name =
  with_write_lock (fun () ->
    load_snapshot_pair_unlocked ~log_restore:false ~base_path ~keeper_name)
;;

let load_snapshot_pair_with_errors ~base_path ~keeper_name =
  with_write_lock (fun () -> load_snapshot_pair_with_errors_unlocked ~base_path ~keeper_name)
;;

let load ~base_path ~keeper_name =
  with_write_lock (fun () -> load_unlocked ~base_path ~keeper_name)

let queue_oldest_arrived_at queue =
  queue
  |> Keeper_event_queue.to_list
  |> List.fold_left
       (fun acc (stimulus : Keeper_event_queue.stimulus) ->
          match acc with
          | None -> Some stimulus.arrived_at
          | Some ts -> Some (Float.min ts stimulus.arrived_at))
       None

let min_float_opt left right =
  match left, right with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some a, Some b -> Some (Float.min a b)

let json_of_float_opt = function
  | None -> `Null
  | Some value -> `Float value

let age_seconds_json ~now = function
  | None -> `Null
  | Some ts -> `Float (Float.max 0.0 (now -. ts))

let read_queue_for_summary ~keeper_name path =
  if not (Sys.file_exists path)
  then Ok Keeper_event_queue.empty
  else
    match Safe_ops.read_json_file_safe path with
    | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
    | Ok json ->
      (match Keeper_event_queue.queue_of_yojson json with
       | Ok queue -> Ok queue
       | Error msg ->
         Error
           (Printf.sprintf
              "%s: failed to parse keeper=%s event queue: %s"
              path
              keeper_name
              msg))

type queue_summary = {
  queue : Keeper_event_queue.t;
  read_error : string option;
}

let queue_summary ~keeper_name path =
  match read_queue_for_summary ~keeper_name path with
  | Ok queue -> { queue; read_error = None }
  | Error msg -> { queue = Keeper_event_queue.empty; read_error = Some msg }

type keeper_queue_summary = {
  keeper_name : string;
  pending_count : int;
  inflight_count : int;
  pending_oldest_arrived_at : float option;
  inflight_oldest_arrived_at : float option;
  read_errors : string list;
}

let keeper_total_count summary = summary.pending_count + summary.inflight_count

let keeper_oldest_arrived_at summary =
  min_float_opt summary.pending_oldest_arrived_at summary.inflight_oldest_arrived_at

let keeper_queue_summary ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg ->
    { keeper_name
    ; pending_count = 0
    ; inflight_count = 0
    ; pending_oldest_arrived_at = None
    ; inflight_oldest_arrived_at = None
    ; read_errors = [ msg ]
    }
  | Ok pending_path, Ok inflight_path ->
    let pending = queue_summary ~keeper_name pending_path in
    let inflight = queue_summary ~keeper_name inflight_path in
    { keeper_name
    ; pending_count = Keeper_event_queue.length pending.queue
    ; inflight_count = Keeper_event_queue.length inflight.queue
    ; pending_oldest_arrived_at = queue_oldest_arrived_at pending.queue
    ; inflight_oldest_arrived_at = queue_oldest_arrived_at inflight.queue
    ; read_errors =
        List.filter_map (fun value -> value) [ pending.read_error; inflight.read_error ]
    }

let keeper_queue_summary_json ~now summary =
  let oldest_arrived_at = keeper_oldest_arrived_at summary in
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "pending_count", `Int summary.pending_count
    ; "inflight_count", `Int summary.inflight_count
    ; "total_count", `Int (keeper_total_count summary)
    ; "oldest_arrived_at_unix", json_of_float_opt oldest_arrived_at
    ; "oldest_age_seconds", age_seconds_json ~now oldest_arrived_at
    ; "pending_oldest_arrived_at_unix", json_of_float_opt summary.pending_oldest_arrived_at
    ; "pending_oldest_age_seconds", age_seconds_json ~now summary.pending_oldest_arrived_at
    ; "inflight_oldest_arrived_at_unix", json_of_float_opt summary.inflight_oldest_arrived_at
    ; "inflight_oldest_age_seconds", age_seconds_json ~now summary.inflight_oldest_arrived_at
    ; "read_errors", `List (List.map (fun msg -> `String msg) summary.read_errors)
    ]

type queue_kind =
  | Pending
  | Inflight

let queue_count_by_keeper_json ~now kind summary =
  let field, count, oldest_arrived_at =
    match kind with
    | Pending -> "pending_count", summary.pending_count, summary.pending_oldest_arrived_at
    | Inflight -> "inflight_count", summary.inflight_count, summary.inflight_oldest_arrived_at
  in
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; field, `Int count
    ; "oldest_age_seconds", age_seconds_json ~now oldest_arrived_at
    ]

let fleet_summary_json ~now ~base_path =
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let discovery = discover_keeper_names_with_snapshots ~base_path in
  let keeper_names = discovery.keeper_names in
  let scan_errors =
    match discovery.read_error with
    | None -> []
    | Some msg -> [ msg ]
  in
  let keepers =
    List.map (fun keeper_name -> keeper_queue_summary ~base_path ~keeper_name) keeper_names
  in
  let pending_count =
    List.fold_left (fun acc summary -> acc + summary.pending_count) 0 keepers
  in
  let inflight_count =
    List.fold_left (fun acc summary -> acc + summary.inflight_count) 0 keepers
  in
  let oldest_arrived_at =
    List.fold_left
      (fun acc summary -> min_float_opt acc (keeper_oldest_arrived_at summary))
      None
      keepers
  in
  let read_errors =
    scan_errors @ List.concat (List.map (fun summary -> summary.read_errors) keepers)
  in
  let read_error_count = List.length read_errors in
  let keepers_with_pending =
    keepers |> List.filter (fun summary -> summary.pending_count > 0)
  in
  let keepers_with_inflight =
    keepers |> List.filter (fun summary -> summary.inflight_count > 0)
  in
  `Assoc
    [ "schema", `String "masc.keeper_event_queue.fleet_summary.v1"
    ; "status", `String (if read_error_count = 0 then "ok" else "degraded")
    ; "operator_action_required", `Bool (read_error_count > 0)
    ; "base_path", `String base_path
    ; "keepers_runtime_dir", `String keepers_dir
    ; "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", `List (List.map (fun name -> `String name) keeper_names)
    ; "pending_count", `Int pending_count
    ; "inflight_count", `Int inflight_count
    ; "total_count", `Int (pending_count + inflight_count)
    ; "oldest_arrived_at_unix", json_of_float_opt oldest_arrived_at
    ; "oldest_age_seconds", age_seconds_json ~now oldest_arrived_at
    ; "pending_by_keeper",
      `List
        (List.map
           (queue_count_by_keeper_json ~now Pending)
           keepers_with_pending)
    ; "inflight_by_keeper",
      `List
        (List.map
           (queue_count_by_keeper_json ~now Inflight)
           keepers_with_inflight)
    ; "read_error_count", `Int read_error_count
    ; "read_errors", `List (List.map (fun msg -> `String msg) read_errors)
    ; "keepers", `List (List.map (keeper_queue_summary_json ~now) keepers)
    ]

let persist_to_path_result ~keeper_name path queue =
  match save_json_atomic path (Keeper_event_queue.queue_to_yojson queue) with
  | Ok () -> Ok ()
  | Error msg ->
    Error
      (Printf.sprintf
         "failed to persist keeper=%s path=%s: %s"
         keeper_name
         path
         msg)

let persist_to_path ~keeper_name path queue =
  match persist_to_path_result ~keeper_name path queue with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

let persist ~base_path ~keeper_name queue =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg
  | Ok path ->
    (try
       with_write_lock (fun () -> persist_to_path ~keeper_name path queue)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "event_queue_snapshot: persist raised keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))

let persist_snapshot ~base_path ~keeper_name snapshot =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg
  | Ok path ->
    (try
       with_write_lock (fun () -> persist_to_path ~keeper_name path (snapshot ()))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "event_queue_snapshot: persist_snapshot raised keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))

let snapshot_read_error_to_string (error : snapshot_read_error) =
  let location =
    match error.path with
    | None -> ""
    | Some path -> " path=" ^ path
  in
  Printf.sprintf
    "%s%s: %s"
    (snapshot_read_error_kind_to_string error.kind)
    location
    error.message

let update_checked_result ?(after_commit = fun () -> ()) ~base_path ~keeper_name f =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         let cur, read_errors = load_from_path_with_errors ~keeper_name path in
         match read_errors with
         | _ :: _ ->
           Error
             (Printf.sprintf
                "refusing to overwrite unreadable event queue keeper=%s: %s"
                keeper_name
                (String.concat
                   "; "
                   (List.map snapshot_read_error_to_string read_errors)))
         | [] ->
           (match f cur with
            | Error _ as err -> err
            | Ok next ->
              (match persist_to_path_result ~keeper_name path next with
               | Error _ as err -> err
               | Ok () ->
                 (* Keep the persistence lock through the live publication. Any
                    ordinary CAS writer can advance the in-memory queue, but its
                    snapshot is serialized after this callback and therefore
                    observes the committed stimulus instead of overwriting it. *)
                 after_commit ();
                 Ok ())))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "update raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn)))

let update_result ?after_commit ~base_path ~keeper_name f =
  update_checked_result
    ?after_commit
    ~base_path
    ~keeper_name
    (fun queue -> Ok (f queue))

let update ~base_path ~keeper_name f =
  match update_result ~base_path ~keeper_name f with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

let record_inflight ~base_path ~keeper_name stimuli =
  match stimuli with
  | [] -> ()
  | _ -> (
  match inflight_path ~base_path ~keeper_name with
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         let cur = load_from_path ~keeper_name path in
         persist_to_path ~keeper_name path (append_missing cur stimuli))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "event_queue_snapshot: record_inflight raised keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn)))

let ack_inflight ~base_path ~keeper_name stimuli =
  (* [ack_inflight] clears the inflight file ONLY. It is used after
     [requeue_front] has put the lease back into the pending snapshot, so the
     stimulus MUST remain pending. Genuine consumed-ack uses [ack_consumed],
     which updates pending and inflight under one lock. *)
  match stimuli with
  | [] -> ()
  | _ -> (
  match inflight_path ~base_path ~keeper_name with
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         let cur = load_from_path ~keeper_name path in
         persist_to_path ~keeper_name path (remove_stimuli cur stimuli))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "event_queue_snapshot: ack_inflight raised keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn)))

let ack_consumed ~base_path ~keeper_name stimuli =
  (* Genuine consumed-ack must remove stimuli from both durable snapshots as one
     synchronized transition. Public [load] takes the same lock, so it cannot
     observe "inflight cleared, pending not drained" or the reverse. *)
  match stimuli with
  | [] -> Ok ()
  | _ -> (
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg -> Error msg
  | Ok pending_path, Ok inflight_path ->
    (try
       with_write_lock (fun () ->
         let pending = load_from_path ~keeper_name pending_path in
         let inflight = load_from_path ~keeper_name inflight_path in
         let pending' = remove_stimuli pending stimuli in
         let inflight' = remove_stimuli inflight stimuli in
         match persist_to_path_result ~keeper_name pending_path pending' with
         | Error _ as err -> err
         | Ok () -> persist_to_path_result ~keeper_name inflight_path inflight')
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "ack_consumed raised keeper=%s pending=%s inflight=%s: %s"
            keeper_name
            pending_path
            inflight_path
            (Printexc.to_string exn))))

let drop_by_post_id ~base_path ~keeper_name ~post_id =
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg -> Error msg
  | Ok pending_path, Ok inflight_path ->
    (try
       with_write_lock (fun () ->
         let pending = load_from_path ~keeper_name pending_path in
         let inflight = load_from_path ~keeper_name inflight_path in
         let removed, pending', inflight' =
           Keeper_event_queue.remove_by_post_id_pair post_id pending inflight
         in
         match persist_to_path_result ~keeper_name pending_path pending' with
         | Error _ as err -> err
         | Ok () ->
           (match persist_to_path_result ~keeper_name inflight_path inflight' with
            | Error _ as err -> err
            | Ok () -> Ok removed))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "drop_by_post_id raised keeper=%s pending=%s inflight=%s post_id=%s: %s"
            keeper_name
            pending_path
            inflight_path
            post_id
            (Printexc.to_string exn)))
