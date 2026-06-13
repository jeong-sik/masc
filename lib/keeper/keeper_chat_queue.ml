(** Keeper_chat_queue — thread-safe per-keeper message queue.

    Each keeper owns an in-memory FIFO queue for chat messages that
    arrive while the keeper is already processing a previous message.
    When a stream finishes, the queue is drained automatically.

    The queue is transient (not persisted).  Lost on server restart.

    @since 2.145.0 *)

type message_source =
  | Dashboard
  | Discord of { channel_id : string; user_id : string }
  | Slack of { channel : string; user_id : string }

type queued_message = {
  content : string;
  attachments : Keeper_chat_store.attachment list;
  timestamp : float;
  source : message_source;
}

type queue_entry = {
  mutex : Eio.Mutex.t;
  q : queued_message Queue.t;
}

(** Global registry protected by a single mutex.
    Per-keeper queues have their own mutex for independent enqueue/dequeue
    parallelism; the global mutex is only for lookup/insertion into the
    registry. *)
let registry_mutex = Eio.Mutex.create ()
let registry : (string, queue_entry) Hashtbl.t = Hashtbl.create 16

let get_or_create_entry keeper_name =
  match Hashtbl.find_opt registry keeper_name with
  | Some entry -> entry
  | None ->
      let entry = { mutex = Eio.Mutex.create (); q = Queue.create () } in
      Hashtbl.add registry keeper_name entry;
      entry

let enqueue ~keeper_name msg =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      let entry = get_or_create_entry keeper_name in
      Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
          Queue.push msg entry.q))

let dequeue ~keeper_name =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      match Hashtbl.find_opt registry keeper_name with
      | None -> None
      | Some entry ->
          Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
              if Queue.is_empty entry.q then None else Some (Queue.pop entry.q)))

let length ~keeper_name =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      match Hashtbl.find_opt registry keeper_name with
      | None -> 0
      | Some entry ->
          Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
              Queue.length entry.q))

let clear ~keeper_name =
  Eio.Mutex.use_rw ~protect:true registry_mutex (fun () ->
      match Hashtbl.find_opt registry keeper_name with
      | None -> ()
      | Some entry ->
          Eio.Mutex.use_rw ~protect:true entry.mutex (fun () ->
              Queue.clear entry.q))
