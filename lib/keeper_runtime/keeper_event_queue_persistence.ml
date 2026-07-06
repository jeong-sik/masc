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

(* [Fs_compat.mkdir_p] raises (Sys_error / Unix_error) on ENOSPC/EROFS/ENOTDIR
   instead of returning a result, so route it through the same [(unit, string)
   result] channel as [save_file_atomic]. This keeps [save_json_atomic] total:
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
    json
    |> Safe_ops.sanitize_json_utf8
    |> Yojson.Safe.pretty_to_string
    |> Fs_compat.save_file_atomic path

let snapshot_path ~base_path ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         "event-queue.json")
  else Error (Printf.sprintf "invalid keeper name for event queue snapshot: %s" keeper_name)

let inflight_path ~base_path ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         "event-queue-inflight.json")
  else Error (Printf.sprintf "invalid keeper name for event queue inflight: %s" keeper_name)

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

let load_from_path_result ~keeper_name path =
  if not (Sys.file_exists path)
  then Ok Keeper_event_queue.empty
  else (
    match Safe_ops.read_json_file_safe path with
    | Error msg ->
      Error
        (Printf.sprintf
           "failed to read keeper=%s path=%s: %s"
           keeper_name
           path
           msg)
    | Ok json ->
      (match Keeper_event_queue.queue_of_yojson json with
       | Error msg ->
         Error
           (Printf.sprintf
              "failed to parse keeper=%s path=%s: %s"
              keeper_name
              path
              msg)
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
         if not (Keeper_event_queue.is_empty deduped)
         then
           Log.Keeper.info
             "event_queue_snapshot: restored %s for keeper=%s"
             (Keeper_event_queue.summary deduped)
             keeper_name;
         Ok deduped))

let load_from_path ~keeper_name path =
  match load_from_path_result ~keeper_name path with
  | Ok queue -> queue
  | Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    Keeper_event_queue.empty

let load_pending_unlocked ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path -> load_from_path_result ~keeper_name path

let load_inflight_unlocked ~base_path ~keeper_name =
  match inflight_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path -> load_from_path_result ~keeper_name path

let load_unlocked_result ~base_path ~keeper_name =
  match
    ( load_pending_unlocked ~base_path ~keeper_name
    , load_inflight_unlocked ~base_path ~keeper_name )
  with
  | Error msg, _ | _, Error msg -> Error msg
  | Ok pending, Ok inflight ->
    Ok (prepend_missing pending (Keeper_event_queue.to_list inflight))

let load_unlocked ~base_path ~keeper_name =
  match load_unlocked_result ~base_path ~keeper_name with
  | Ok queue -> queue
  | Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    Keeper_event_queue.empty

let load ~base_path ~keeper_name =
  with_write_lock (fun () -> load_unlocked ~base_path ~keeper_name)

let load_result ~base_path ~keeper_name =
  with_write_lock (fun () -> load_unlocked_result ~base_path ~keeper_name)

let load_pending ~base_path ~keeper_name =
  with_write_lock (fun () -> load_pending_unlocked ~base_path ~keeper_name)

let load_inflight ~base_path ~keeper_name =
  with_write_lock (fun () -> load_inflight_unlocked ~base_path ~keeper_name)

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

let persist_result ~base_path ~keeper_name queue =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       with_write_lock (fun () -> persist_to_path_result ~keeper_name path queue)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "persist raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn)))

let persist ~base_path ~keeper_name queue =
  match persist_result ~base_path ~keeper_name queue with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

let persist_snapshot_result ~base_path ~keeper_name snapshot =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       with_write_lock (fun () -> persist_to_path_result ~keeper_name path (snapshot ()))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "persist_snapshot raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn)))

let persist_snapshot ~base_path ~keeper_name snapshot =
  match persist_snapshot_result ~base_path ~keeper_name snapshot with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

let update_result ~base_path ~keeper_name f =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         match load_from_path_result ~keeper_name path with
         | Error _ as err -> err
         | Ok cur -> persist_to_path_result ~keeper_name path (f cur))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "update raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn)))

let update ~base_path ~keeper_name f =
  match update_result ~base_path ~keeper_name f with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

let record_inflight_result ~base_path ~keeper_name stimuli =
  match stimuli with
  | [] -> Ok ()
  | _ -> (
  match inflight_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         match load_from_path_result ~keeper_name path with
         | Error _ as err -> err
         | Ok cur -> persist_to_path_result ~keeper_name path (append_missing cur stimuli))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "record_inflight raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn))))

let record_inflight ~base_path ~keeper_name stimuli =
  match record_inflight_result ~base_path ~keeper_name stimuli with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

let ack_inflight_result ~base_path ~keeper_name stimuli =
  (* [ack_inflight] clears the inflight file ONLY. It is used after
     [requeue_front] has put the lease back into the pending snapshot, so the
     stimulus MUST remain pending. Genuine consumed-ack uses [ack_consumed],
     which updates pending and inflight under one lock. *)
  match stimuli with
  | [] -> Ok ()
  | _ -> (
  match inflight_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         match load_from_path_result ~keeper_name path with
         | Error _ as err -> err
         | Ok cur -> persist_to_path_result ~keeper_name path (remove_stimuli cur stimuli))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "ack_inflight raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn))))

let ack_inflight ~base_path ~keeper_name stimuli =
  match ack_inflight_result ~base_path ~keeper_name stimuli with
  | Ok () -> ()
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg

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
         match load_from_path_result ~keeper_name pending_path with
         | Error _ as err -> err
         | Ok pending ->
           (match load_from_path_result ~keeper_name inflight_path with
            | Error _ as err -> err
            | Ok inflight ->
              let pending' = remove_stimuli pending stimuli in
              let inflight' = remove_stimuli inflight stimuli in
              (match persist_to_path_result ~keeper_name pending_path pending' with
               | Error _ as err -> err
               | Ok () -> persist_to_path_result ~keeper_name inflight_path inflight')))
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
         match load_from_path_result ~keeper_name pending_path with
         | Error _ as err -> err
         | Ok pending ->
           (match load_from_path_result ~keeper_name inflight_path with
            | Error _ as err -> err
            | Ok inflight ->
              let removed, pending', inflight' =
                Keeper_event_queue.remove_by_post_id_pair post_id pending inflight
              in
              (match persist_to_path_result ~keeper_name pending_path pending' with
               | Error _ as err -> err
               | Ok () ->
                 (match persist_to_path_result ~keeper_name inflight_path inflight' with
                  | Error _ as err -> err
                  | Ok () -> Ok removed))))
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
