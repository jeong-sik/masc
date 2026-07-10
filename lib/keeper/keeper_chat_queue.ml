(** Keeper_chat_queue — thread-safe per-keeper message queue.

    Each keeper owns an in-memory FIFO queue for chat messages that
    arrive while the keeper is already processing a previous message.
    When a stream finishes, the queue is drained automatically.

    Queue contents can be mirrored to a per-keeper durable snapshot once
    [configure_persistence] is called from server bootstrap.  This keeps
    queued connector/dashboard follow-up messages replayable across restart.

    @since 2.145.0 *)

type message_source =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

type queued_message = {
  content : string;
  user_blocks : Keeper_multimodal_input.user_input_block list;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
}

let dashboard_queue_default_thread_id = "dashboard"

let dashboard_thread_id_or_default = function
  | Some thread_id -> thread_id
  | None ->
    (* DET-OK: queued dashboard messages without AG-UI thread metadata are routed
       to the documented singleton dashboard lane, not inferred from runtime
       state. *)
    dashboard_queue_default_thread_id

let continuation_channel_of_message_source ?dashboard_thread_id = function
  | Dashboard ->
    let thread_id = dashboard_thread_id_or_default dashboard_thread_id in
    Keeper_continuation_channel.Dashboard { thread_id }
  | Discord { channel_id; user_id } ->
    Keeper_continuation_channel.Discord
      { guild_id = None
      ; channel_id
      ; parent_channel_id = None
      ; thread_id = None
      ; user_id
      }
  | Slack { channel; user_id } ->
    Keeper_continuation_channel.Slack
      { team_id = None; channel_id = channel; thread_ts = None; user_id }

type queue_entry = {
  mutex : Eio.Mutex.t;
  q : queued_message Queue.t;
}

let schema = "keeper_chat_queue.v1"
let persistence_file = "chat-queue.json"
let persistence_base_path : string option Atomic.t = Atomic.make None
let fail_next_persist_for_testing = Atomic.make false

exception Persistence_failed of string

(** Global registry protected by a single mutex.
    Per-keeper queues have their own mutex for independent enqueue/dequeue
    parallelism; the global mutex is only for lookup/insertion into the
    registry. *)
let registry_mutex = Eio.Mutex.create ()
let registry : (string, queue_entry) Hashtbl.t = Hashtbl.create 16

let valid_keeper_name name =
  let valid_char = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  (not (String.equal name "")) && String.for_all valid_char name

let snapshot_path ~base_path ~keeper_name =
  if valid_keeper_name keeper_name
  then
    Ok
      (Filename.concat
         (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) keeper_name)
         persistence_file)
  else Error (Printf.sprintf "invalid keeper name for chat queue snapshot: %s" keeper_name)

let source_to_yojson = function
  | Dashboard -> `Assoc [ ("kind", `String "dashboard") ]
  | Discord { channel_id; user_id } ->
    `Assoc
      [ ("kind", `String "discord")
      ; ("channel_id", `String channel_id)
      ; ("user_id", `String user_id)
      ]
  | Slack { channel; user_id } ->
    `Assoc
      [ ("kind", `String "slack")
      ; ("channel", `String channel)
      ; ("user_id", `String user_id)
      ]

let source_of_yojson json =
  match Json_util.get_string json "kind" with
  | Some "dashboard" -> Ok Dashboard
  | Some "discord" ->
    let channel_id =
      Json_util.get_string_with_default json ~key:"channel_id" ~default:""
    in
    let user_id = Json_util.get_string_with_default json ~key:"user_id" ~default:"" in
    if String.trim channel_id = "" || String.trim user_id = ""
    then Error "discord chat queue source requires channel_id and user_id"
    else Ok (Discord { channel_id; user_id })
  | Some "slack" ->
    let channel = Json_util.get_string_with_default json ~key:"channel" ~default:"" in
    let user_id = Json_util.get_string_with_default json ~key:"user_id" ~default:"" in
    if String.trim channel = "" || String.trim user_id = ""
    then Error "slack chat queue source requires channel and user_id"
    else Ok (Slack { channel; user_id })
  | Some kind -> Error (Printf.sprintf "unsupported chat queue source kind: %s" kind)
  | None -> Error "chat queue source requires kind"

let queued_message_to_yojson (msg : queued_message) =
  `Assoc
    [ ("content", `String msg.content)
    ; ("user_blocks", Keeper_multimodal_input.user_blocks_to_yojson msg.user_blocks)
    ; ("attachments", Keeper_multimodal_input.attachments_to_yojson msg.attachments)
    ; ("timestamp", `Float msg.timestamp)
    ; ("source", source_to_yojson msg.source)
    ]

let queued_message_of_yojson json =
  match json with
  | `Assoc _ ->
    let content = Json_util.get_string_with_default json ~key:"content" ~default:"" in
    (match Json_util.get_float json "timestamp" with
     | None -> Error "chat queue message requires timestamp"
     | Some timestamp ->
       let attachments = Keeper_multimodal_input.parse_attachments json in
       (match Keeper_multimodal_input.parse_user_blocks json with
        | Error err -> Error err
        | Ok user_blocks ->
          (match Json_util.assoc_member_opt "source" json with
           | None -> Error "chat queue message requires source"
           | Some source_json ->
             (match source_of_yojson source_json with
              | Error err -> Error err
              | Ok source -> Ok { content; user_blocks; attachments; timestamp; source }))))
  | _ -> Error "chat queue message must be a JSON object"

let queue_to_list q =
  let acc = ref [] in
  Queue.iter (fun item -> acc := item :: !acc) q;
  List.rev !acc

let queue_of_list items =
  let q = Queue.create () in
  List.iter (fun item -> Queue.push item q) items;
  q

let replace_queue q items =
  Queue.clear q;
  List.iter (fun item -> Queue.push item q) items

let queue_to_yojson q =
  `Assoc
    [ ("schema", `String schema)
    ; ("items", `List (List.map queued_message_to_yojson (queue_to_list q)))
    ]

let queue_of_yojson json =
  match (Json_util.get_string json "schema", Json_util.assoc_member_opt "items" json) with
  | Some s, _ when not (String.equal s schema) ->
    Error (Printf.sprintf "unexpected chat queue snapshot schema: %s" s)
  | None, _ -> Error "chat queue snapshot requires schema"
  | Some _, Some (`List items) ->
    let rec loop acc = function
      | [] -> Ok (queue_of_list (List.rev acc))
      | item :: rest ->
        (match queued_message_of_yojson item with
         | Ok parsed -> loop (parsed :: acc) rest
         | Error err -> Error err)
    in
    loop [] items
  | Some _, _ -> Error "chat queue snapshot requires items array"

let save_json_atomic path json =
  Fs_compat.mkdir_p (Filename.dirname path);
  json
  |> Safe_ops.sanitize_json_utf8
  |> Yojson.Safe.pretty_to_string
  |> Fs_compat.save_file_atomic path

let load_snapshot ~base_path ~keeper_name =
  match snapshot_path ~base_path ~keeper_name with
  | Error msg ->
    Log.Keeper.warn "chat_queue_snapshot: %s" msg;
    Queue.create ()
  | Ok path ->
    if not (Sys.file_exists path)
    then Queue.create ()
    else (
      match Safe_ops.read_json_file_safe path with
      | Error msg ->
        Log.Keeper.warn
          "chat_queue_snapshot: failed to read keeper=%s path=%s: %s"
          keeper_name
          path
          msg;
        Queue.create ()
      | Ok json ->
        (match queue_of_yojson json with
         | Ok q ->
           if Queue.length q > 0
           then
             Log.Keeper.info
               "chat_queue_snapshot: restored %d queued messages for keeper=%s"
               (Queue.length q)
               keeper_name;
           q
         | Error msg ->
           Log.Keeper.warn
             "chat_queue_snapshot: failed to parse keeper=%s path=%s: %s"
             keeper_name
             path
             msg;
           Queue.create ()))

let persist_snapshot ~base_path ~keeper_name q =
  if Atomic.exchange fail_next_persist_for_testing false
  then Error "injected chat queue persist failure"
  else match snapshot_path ~base_path ~keeper_name with
  | Error msg -> Error msg
  | Ok path ->
    (try
       match save_json_atomic path (queue_to_yojson q) with
       | Ok () -> Ok ()
       | Error msg ->
         Error
           (Printf.sprintf
              "failed to persist keeper=%s path=%s: %s"
              keeper_name
              path
              msg)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (Printf.sprintf
            "persist raised keeper=%s path=%s: %s"
            keeper_name
            path
            (Printexc.to_string exn)))

let persist_if_configured ~keeper_name q =
  match Atomic.get persistence_base_path with
  | None -> ()
  | Some base_path ->
    (match persist_snapshot ~base_path ~keeper_name q with
     | Ok () -> ()
     | Error msg -> raise (Persistence_failed msg))

let persist_or_rollback ~keeper_name q ~before =
  try persist_if_configured ~keeper_name q with
  | Eio.Cancel.Cancelled _ as exn ->
    replace_queue q before;
    raise exn
  | exn ->
    replace_queue q before;
    raise exn

let persistence_configured () =
  match Atomic.get persistence_base_path with
  | None -> false
  | Some _ -> true

let get_or_create_entry keeper_name =
  match Hashtbl.find_opt registry keeper_name with
  | Some entry -> entry
  | None ->
      let entry = { mutex = Eio.Mutex.create (); q = Queue.create () } in
      Hashtbl.add registry keeper_name entry;
      entry

let get_or_create_entry_locked keeper_name =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      get_or_create_entry keeper_name)

let find_entry keeper_name =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      Hashtbl.find_opt registry keeper_name)

let with_entry_lock entry f =
  match
    Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
        try Ok (f ()) with
        | exn -> Error (exn, Printexc.get_raw_backtrace ()))
  with
  | Ok value -> value
  | Error (exn, bt) -> Printexc.raise_with_backtrace exn bt

let enqueue ~keeper_name msg =
  let entry = get_or_create_entry_locked keeper_name in
  with_entry_lock entry (fun () ->
      let before = queue_to_list entry.q in
      Queue.push msg entry.q;
      persist_or_rollback ~keeper_name entry.q ~before)

let dequeue ~keeper_name =
  match find_entry keeper_name with
  | None -> None
  | Some entry ->
      with_entry_lock entry (fun () ->
          if Queue.is_empty entry.q
          then None
          else (
            let before = queue_to_list entry.q in
            let msg = Queue.pop entry.q in
            persist_or_rollback ~keeper_name entry.q ~before;
            Some msg))

let same_source a b =
  match (a, b) with
  | Dashboard, Dashboard -> true
  | ( Discord { channel_id = c1; user_id = u1 },
      Discord { channel_id = c2; user_id = u2 } ) ->
      String.equal c1 c2 && String.equal u1 u2
  | Slack { channel = c1; user_id = u1 }, Slack { channel = c2; user_id = u2 }
    ->
      String.equal c1 c2 && String.equal u1 u2
  | Dashboard, (Discord _ | Slack _)
  | Discord _, (Dashboard | Slack _)
  | Slack _, (Dashboard | Discord _) ->
      false

let dequeue_batch ~keeper_name =
  match find_entry keeper_name with
  | None -> []
  | Some entry ->
      with_entry_lock entry (fun () ->
          let before = queue_to_list entry.q in
          match Queue.take_opt entry.q with
          | None -> []
          | Some first ->
              let rec drain acc =
                match Queue.peek_opt entry.q with
                | Some next when same_source first.source next.source ->
                    let next = Queue.pop entry.q in
                    drain (next :: acc)
                | Some _ | None -> List.rev acc
              in
              let batch = first :: drain [] in
              persist_or_rollback ~keeper_name entry.q ~before;
              batch)

let merge_batch batch =
  match batch with
  | [] -> None
  | [ msg ] -> Some msg
  | first :: _ ->
      Some
        {
          content = String.concat "\n\n" (List.map (fun m -> m.content) batch);
          user_blocks = List.concat_map (fun m -> m.user_blocks) batch;
          attachments = List.concat_map (fun m -> m.attachments) batch;
          timestamp = first.timestamp;
          source = first.source;
        }

let rec list_equal equal xs ys =
  match xs, ys with
  | [], [] -> true
  | x :: xs, y :: ys -> equal x y && list_equal equal xs ys
  | [], _ :: _ | _ :: _, [] -> false

let option_equal equal a b =
  match a, b with
  | None, None -> true
  | Some a, Some b -> equal a b
  | None, Some _ | Some _, None -> false

let user_media_block_equal
      (a : Keeper_multimodal_input.user_media_block)
      (b : Keeper_multimodal_input.user_media_block)
  =
  String.equal a.attachment_id b.attachment_id
  && String.equal a.name b.name
  && String.equal a.mime_type b.mime_type
  && option_equal Int.equal a.size b.size

let user_input_block_equal a b =
  match a, b with
  | Keeper_multimodal_input.User_text a, Keeper_multimodal_input.User_text b ->
      String.equal a b
  | Keeper_multimodal_input.User_image a, Keeper_multimodal_input.User_image b ->
      user_media_block_equal a b
  | Keeper_multimodal_input.User_document a, Keeper_multimodal_input.User_document b ->
      user_media_block_equal a b
  | Keeper_multimodal_input.User_audio a, Keeper_multimodal_input.User_audio b ->
      user_media_block_equal a b
  | ( Keeper_multimodal_input.User_text _,
      ( Keeper_multimodal_input.User_image _
      | Keeper_multimodal_input.User_document _
      | Keeper_multimodal_input.User_audio _ ) )
  | ( Keeper_multimodal_input.User_image _,
      ( Keeper_multimodal_input.User_text _
      | Keeper_multimodal_input.User_document _
      | Keeper_multimodal_input.User_audio _ ) )
  | ( Keeper_multimodal_input.User_document _,
      ( Keeper_multimodal_input.User_text _
      | Keeper_multimodal_input.User_image _
      | Keeper_multimodal_input.User_audio _ ) )
  | ( Keeper_multimodal_input.User_audio _,
      ( Keeper_multimodal_input.User_text _
      | Keeper_multimodal_input.User_image _
      | Keeper_multimodal_input.User_document _ ) ) ->
      false

let attachment_equal (a : Keeper_chat_store.attachment) (b : Keeper_chat_store.attachment) =
  String.equal a.id b.id
  && String.equal a.att_type b.att_type
  && String.equal a.name b.name
  && Int.equal a.size b.size
  && String.equal a.mime_type b.mime_type
  && String.equal a.data b.data

let message_source_equal a b =
  match a, b with
  | Dashboard, Dashboard -> true
  | Discord { channel_id = c1; user_id = u1 }, Discord { channel_id = c2; user_id = u2 } ->
      String.equal c1 c2 && String.equal u1 u2
  | Slack { channel = c1; user_id = u1 }, Slack { channel = c2; user_id = u2 } ->
      String.equal c1 c2 && String.equal u1 u2
  | Dashboard, (Discord _ | Slack _)
  | Discord _, (Dashboard | Slack _)
  | Slack _, (Dashboard | Discord _) ->
      false

let queued_message_equal (a : queued_message) (b : queued_message) =
  String.equal a.content b.content
  && list_equal user_input_block_equal a.user_blocks b.user_blocks
  && list_equal attachment_equal a.attachments b.attachments
  && Float.equal a.timestamp b.timestamp
  && message_source_equal a.source b.source

(* Remove the first message structurally equal to [target] from the head run —
   the leading messages sharing the head message's source, i.e. the exact set
   [dequeue_batch] coalesces into one turn. Returns the item list with that one
   message dropped, or [None] when no head-run message matches. Confining the
   search to the head run keeps [remove_matching] and [dequeue_batch] acting on
   the same region under the shared per-keeper mutex, so a queued message is
   answered by at most one of them. *)
let remove_first_in_head_run items target =
  match items with
  | [] -> None
  | head :: _ ->
      let rec loop acc = function
        | [] -> None
        | msg :: rest ->
            if not (same_source head.source msg.source)
            then None
            else if queued_message_equal msg target
            then Some (List.rev_append acc rest)
            else loop (msg :: acc) rest
      in
      loop [] items

let remove_matching ~keeper_name target =
  match find_entry keeper_name with
  | None -> `Not_found
  | Some entry ->
      with_entry_lock entry (fun () ->
          let before = queue_to_list entry.q in
          match remove_first_in_head_run before target with
          | None -> `Not_found
          | Some remaining ->
              replace_queue entry.q remaining;
              (* Reuse the persist-abort idiom: on snapshot rewrite failure
                 [persist_or_rollback] restores [before] and re-raises, so the
                 removal is aborted (queue unchanged) before it is reported.
                 Only [Persistence_failed] becomes a typed result; [Cancelled]
                 and any other exception still propagate. *)
              (try
                 persist_or_rollback ~keeper_name entry.q ~before;
                 `Removed
               with Persistence_failed msg -> `Persist_failed msg))

let length ~keeper_name =
  match find_entry keeper_name with
  | None -> 0
  | Some entry ->
      with_entry_lock entry (fun () -> Queue.length entry.q)

let snapshot ~keeper_name =
  match find_entry keeper_name with
  | None -> []
  | Some entry ->
      with_entry_lock entry (fun () -> queue_to_list entry.q)

let clear ~keeper_name =
  match find_entry keeper_name with
  | None -> ()
  | Some entry ->
      with_entry_lock entry (fun () ->
          let before = queue_to_list entry.q in
          Queue.clear entry.q;
          persist_or_rollback ~keeper_name entry.q ~before)

let all_keeper_names () =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      Hashtbl.fold (fun name _ acc -> name :: acc) registry [])

let configure_persistence ~base_path =
  Atomic.set persistence_base_path (Some base_path);
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  if Sys.file_exists keepers_dir && Sys.is_directory keepers_dir
  then
    Sys.readdir keepers_dir
    |> Array.iter (fun keeper_name ->
      if valid_keeper_name keeper_name
      then
        let q = load_snapshot ~base_path ~keeper_name in
        if Queue.length q > 0
        then
          let snapshot_items = queue_to_list q in
          let entry = get_or_create_entry_locked keeper_name in
          with_entry_lock entry (fun () ->
              let before = queue_to_list entry.q in
              replace_queue entry.q (snapshot_items @ before);
              persist_or_rollback ~keeper_name entry.q ~before))

module For_testing = struct
  let reset () =
    Atomic.set fail_next_persist_for_testing false;
    Atomic.set persistence_base_path None;
    Eio.Mutex.use_rw ~protect:true registry_mutex (fun () -> Hashtbl.clear registry)

  let fail_next_persist () = Atomic.set fail_next_persist_for_testing true
end
