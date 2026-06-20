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

let load ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg ->
    Log.Keeper.warn "event_queue_snapshot: %s" msg;
    Keeper_event_queue.empty
  | Ok path ->
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

let persist ~base_path ~keeper_name queue =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Log.Keeper.warn "event_queue_snapshot: %s" msg
  | Ok path ->
    (try
       with_write_lock (fun () ->
         match save_json_atomic path (Keeper_event_queue.queue_to_yojson queue) with
         | Ok () -> ()
         | Error msg ->
           Log.Keeper.warn
             "event_queue_snapshot: failed to persist keeper=%s path=%s: %s"
             keeper_name
             path
             msg)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         "event_queue_snapshot: persist raised keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))
