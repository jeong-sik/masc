(** Durable snapshot store for per-keeper Event Layer queues.

    The registry keeps the live queue in [registry_entry.event_queue]. This
    module mirrors the post-CAS queue snapshot to disk so a keeper restart can
    replay pending stimuli instead of resetting to [Keeper_event_queue.empty].

    Writes are serialized with an Eio mutex in runtime fibers. Setup/tests that
    reach this module without an Eio context fall back to a Stdlib mutex. *)

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

let load ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name, inflight_path ~base_path ~keeper_name with
  | Error msg, _ | _, Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    Keeper_event_queue.empty
  | Ok pending_path, Ok inflight_path ->
    let pending = load_from_path ~keeper_name pending_path in
    let inflight = load_from_path ~keeper_name inflight_path in
    prepend_missing pending (Keeper_event_queue.to_list inflight)

let persist_to_path ~keeper_name path queue =
  match save_json_atomic path (Keeper_event_queue.queue_to_yojson queue) with
  | Ok () -> ()
  | Error msg ->
    Log.Keeper.warn
      "event_queue_snapshot: failed to persist keeper=%s path=%s: %s"
      keeper_name
      path
      msg

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
  (* [ack_inflight] clears the inflight file ONLY. It is shared by the genuine
     ack path ([Keeper_registry_event_queue.ack_consumed]) AND by [requeue_front]
     — whose contract is "put the lease back", i.e. the stimulus MUST remain in
     the pending snapshot. Draining the pending snapshot here would break
     [requeue_front] (regression caught by the requeue-front integration test).
     Pending-snapshot drain for a consumed stimulus lives in
     [drain_pending_snapshot], called only by [ack_consumed]. *)
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

(* A-fix (RFC: keeper-orphan-stimulus-persistence): a *consumed* stimulus — one
   whose turn completed and was acknowledged via
   [Keeper_registry_event_queue.ack_consumed] — must also be drained from the
   pending snapshot, not only the inflight file. A race between dequeue
   (record_inflight) and load (prepend_missing, which folds inflight back into
   the pending snapshot) can otherwise re-materialize an acknowledged stimulus in
   the pending snapshot, where it accumulates across restarts — verified
   2026-06-27: 8–70 bootstrap copies per keeper's event-queue.json while
   event-queue-inflight.json stayed empty. This is the genuine-ack path only;
   [requeue_front] does not call it. *)
let drain_pending_snapshot ~base_path ~keeper_name stimuli =
  match stimuli with
  | [] -> ()
  | _ -> (
  match snapshot_path ~base_path ~keeper_name with
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
         "event_queue_snapshot: drain_pending_snapshot raised keeper=%s path=%s: \
          %s"
         keeper_name
         path
         (Printexc.to_string exn)))
