(** Durable snapshot store for per-keeper Event Layer queues.

    The registry keeps the live queue in [registry_entry.event_queue]. This
    module mirrors the post-CAS queue snapshot to disk so a keeper restart can
    replay pending stimuli instead of resetting to [Keeper_event_queue.empty].

    Reads and writes over the pending/inflight snapshot pair are serialized with
    an Eio mutex in runtime fibers. Setup/tests that reach this module without
    an Eio context fall back to a Stdlib mutex. *)

let eio_write_mu = Eio.Mutex.create ()
let fallback_write_mu = Stdlib.Mutex.create ()

let with_write_lock f =
  match Eio_context.get_switch_opt () with
  | Some _ -> Eio.Mutex.use_rw ~protect:true eio_write_mu f
  | None -> Stdlib.Mutex.protect fallback_write_mu f

let valid_keeper_name name =
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  (not (String.equal name "")) && String.for_all valid_char name

let save_json_atomic path json =
  Fs_compat.mkdir_p (Filename.dirname path);
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
  | Some (head, rest) -> head = stimulus || queue_contains rest stimulus

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
    let remove stimulus = List.exists (fun target -> target = stimulus) stimuli in
    queue
    |> Keeper_event_queue.to_list
    |> List.filter (fun stimulus -> not (remove stimulus))
    |> queue_of_list

let load_from_path ~keeper_name path =
  if not (Sys.file_exists path)
  then Keeper_event_queue.empty
  else (
    match Safe_ops.read_json_file_safe path with
    | Error msg ->
      Log.Keeper.warn
        "event_queue_snapshot: failed to read keeper=%s path=%s: %s"
        keeper_name
        path
        msg;
      Keeper_event_queue.empty
    | Ok json ->
      (match Keeper_event_queue.queue_of_yojson json with
       | Error msg ->
         Log.Keeper.warn
           "event_queue_snapshot: failed to parse keeper=%s path=%s: %s"
           keeper_name
           path
           msg;
         Keeper_event_queue.empty
       | Ok queue ->
         if not (Keeper_event_queue.is_empty queue)
         then
           Log.Keeper.info
             "event_queue_snapshot: restored %s for keeper=%s"
             (Keeper_event_queue.summary queue)
             keeper_name;
         queue))

let load_unlocked ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    Keeper_event_queue.empty
  | Ok pending_path, Ok inflight_path ->
    let pending = load_from_path ~keeper_name pending_path in
    let inflight = load_from_path ~keeper_name inflight_path in
    prepend_missing pending (Keeper_event_queue.to_list inflight)

let load ~base_path ~keeper_name =
  with_write_lock (fun () -> load_unlocked ~base_path ~keeper_name)

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

let update ~base_path ~keeper_name f =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         let cur = load_from_path ~keeper_name path in
         persist_to_path ~keeper_name path (f cur))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "event_queue_snapshot: update raised keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))

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
