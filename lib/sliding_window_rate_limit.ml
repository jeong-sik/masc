(** Sliding Window Rate Limiter for masc

    Implements a sliding-window algorithm using per-key timestamp queues.
    Each key's request timestamps are stored as a Queue of float seconds
    (from Unix.gettimeofday). On each check, timestamps older than
    [now - window_sec] are evicted; if the queue length is below
    [max_requests] the request is allowed and its timestamp appended.

    @since 0.5.0 *)

module StringMap = Set_util.StringMap

type entry = {
  timestamps : float Queue.t;
  mutable last_access : float;
}

type t = {
  window_sec : float;
  max_requests : int;
  mutable entries : entry StringMap.t;
  mutex : Eio.Mutex.t;
}

let create ~window_sec ~max_requests () =
  { window_sec; max_requests; entries = StringMap.empty;
    mutex = Eio.Mutex.create () }

let window_sec t = t.window_sec
let max_requests t = t.max_requests

let now () = Unix.gettimeofday ()

let prune_queue ~window_start q =
  (* Remove timestamps that have fallen outside the window *)
  while not (Queue.is_empty q) && Queue.peek q < window_start do
    ignore (Queue.take q)
  done

let check t ~key =
  let n = now () in
  let window_start = n -. t.window_sec in
  Eio.Mutex.use_rw t.mutex (fun () ->
    let entry =
      match StringMap.find_opt key t.entries with
      | Some e ->
        e.last_access <- n;
        e
      | None ->
        let e = { timestamps = Queue.create (); last_access = n } in
        t.entries <- StringMap.add key e t.entries;
        e
    in
    prune_queue ~window_start entry.timestamps;
    let count = Queue.length entry.timestamps in
    if count < t.max_requests then (
      Queue.add n entry.timestamps;
      true
    ) else
      false
  )

let remaining t ~key =
  let n = now () in
  let window_start = n -. t.window_sec in
  Eio.Mutex.use_rw t.mutex (fun () ->
    match StringMap.find_opt key t.entries with
    | None -> t.max_requests
    | Some entry ->
      prune_queue ~window_start entry.timestamps;
      t.max_requests - Queue.length entry.timestamps
  )

let cleanup t ~older_than_seconds =
  let cutoff = now () -. older_than_seconds in
  Eio.Mutex.use_rw t.mutex (fun () ->
    let keep, removed =
      StringMap.filter_map (fun key entry ->
        if entry.last_access < cutoff then None
        else Some entry
      ) t.entries
    in
    let removed_count = StringMap.cardinal t.entries - StringMap.cardinal keep in
    t.entries <- keep;
    removed_count
  )