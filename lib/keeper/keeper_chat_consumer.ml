(** Keeper_chat_consumer — standalone polling fiber for queue drain.

    Messages from the same source that accumulate in the queue while a
    keeper is busy are coalesced (merged) into a single turn to avoid
    redundant dispatches. *)

let poll_interval_sec =
  match Sys.getenv_opt "MASC_KEEPER_QUEUE_POLL_SEC" with
  | Some s -> (
      try float_of_string s with Failure _ -> 1.0)
  | None -> 1.0

(** [source_key s] returns a comparable string that identifies the
    source for coalescing purposes.  Two messages with the same
    source_key originate from the same conversation channel and can be
    merged into one turn. *)
let source_key = function
  | Keeper_chat_queue.Dashboard -> "dashboard"
  | Keeper_chat_queue.Discord { channel_id; _ } -> "discord:" ^ channel_id
  | Keeper_chat_queue.Slack { channel; _ } -> "slack:" ^ channel

(** [merge_messages msgs] concatenates the content of all messages
    (separated by newlines), merges their attachment lists (preserving
    order, dedup by identity), and uses the earliest timestamp. *)
let merge_messages msgs =
  let buf = Buffer.create 256 in
  let seen = Hashtbl.create 16 in
  let all_attachments = ref [] in
  let first_ts = ref infinity in
  let first_source = ref (Keeper_chat_queue.Dashboard) in
  List.iter
    (fun (m : Keeper_chat_queue.queued_message) ->
       if Buffer.length buf > 0 then Buffer.add_char buf '\n';
       Buffer.add_string buf m.content;
       List.iter
         (fun a ->
            let h = Hashtbl.hash a in
            if not (Hashtbl.mem seen h) then (
              Hashtbl.add seen h ();
              all_attachments := a :: !all_attachments))
         m.attachments;
       if m.timestamp < !first_ts then (
         first_ts := m.timestamp;
         first_source := m.source))
    msgs;
  { Keeper_chat_queue.content = Buffer.contents buf;
    attachments = List.rev !all_attachments;
    timestamp = !first_ts;
    source = !first_source }

(** [group_and_merge msgs] groups messages by [source_key], merges
    each group, and returns one merged message per source. *)
let group_and_merge msgs =
  let groups = Hashtbl.create 8 in
  List.iter
    (fun (m : Keeper_chat_queue.queued_message) ->
       let key = source_key m.source in
       match Hashtbl.find_opt groups key with
       | None -> Hashtbl.add groups key [m]
       | Some lst -> Hashtbl.replace groups key (m :: lst))
    msgs;
  Hashtbl.fold (fun _key group acc -> merge_messages (List.rev group) :: acc)
    groups []

(** [is_cancelled exn] returns [true] if [exn] is [Eio.Cancel.Cancelled]. *)
let is_cancelled exn =
  match exn with Eio.Cancel.Cancelled _ -> true | _ -> false

let start ~sw ~clock ~handle_turn =
  let rec poll_loop () =
    let keeper_names = Keeper_chat_queue.all_keeper_names () in
    List.iter
      (fun keeper_name ->
         let msgs = Keeper_chat_queue.drain_all ~keeper_name in
         if msgs <> [] then
           let merged = group_and_merge msgs in
           let count = List.length merged in
           if count > 0 then
             List.iter
               (fun queued ->
                  (try handle_turn ~sw ~keeper_name ~queued_message:queued with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                       Log.Keeper.warn
                         "keeper_chat_consumer: handle_turn failed for \
                          keeper=%s: %s"
                         keeper_name (Printexc.to_string exn)))
               merged)
      keeper_names;
    Eio.Time.sleep clock poll_interval_sec;
    poll_loop ()
  in
  Eio.Fiber.fork ~sw poll_loop
