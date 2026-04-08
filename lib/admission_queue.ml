(** Admission_queue — MASC-layer priority admission queue for inference calls.

    Mirrors OAS Slot_scheduler design (priority sorted waiter list,
    Eio.Promise blocking, Atomic cancel flag) at the MASC layer with
    MASC-visible waiter metadata for observability.

    @since 3.0.0 *)

(* ── Types ─────────────────────────────────────────────── *)

type waiter_info = {
  keeper_name : string;
  cascade_name : string;
  enqueue_ts : float;
  priority : Llm_provider.Request_priority.t;
}

type snapshot = {
  max_concurrent : int;
  active : int;
  available : int;
  queue_depth : int;
  waiters : waiter_info list;
}

type waiter = {
  rank : int;
  info : waiter_info;
  resolver : unit Eio.Promise.u;
  cancelled : bool Atomic.t;
}

type t = {
  mutable max_slots : int;
  mutable active : int;
  mutable waiters : waiter list;
  mutex : Eio.Mutex.t;
}

(* ── Sorted Insertion ──────────────────────────────────── *)

(** Insert waiter in priority order (lower rank = higher priority = front).
    Stable: equal-rank waiters maintain FIFO order. *)
let insert_sorted entry ws =
  let rec go acc = function
    | [] -> List.rev (entry :: acc)
    | (w :: rest) as tail ->
      if entry.rank <= w.rank then
        List.rev_append acc (entry :: tail)
      else
        go (w :: acc) rest
  in
  go [] ws

(* ── Core Queue ────────────────────────────────────────── *)

let global : t = {
  max_slots = (
    let env_val =
      try int_of_string (Sys.getenv "MASC_ADMISSION_MAX_CONCURRENT")
      with Not_found | Failure _ ->
        try int_of_string (Sys.getenv "OLLAMA_NUM_PARALLEL")
        with Not_found | Failure _ -> 4
    in
    max 1 env_val
  );
  active = 0;
  waiters = [];
  mutex = Eio.Mutex.create ();
}

let now_ts () = Unix.gettimeofday ()

let rec acquire ~priority ~keeper_name ~cascade_name t =
  let resolved = Llm_provider.Request_priority.resolve priority in
  let rank = Llm_provider.Request_priority.to_int resolved in
  let action =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      if t.active < t.max_slots then (
        t.active <- t.active + 1;
        `Got_slot
      ) else (
        let p, r = Eio.Promise.create () in
        let info = {
          keeper_name;
          cascade_name;
          enqueue_ts = now_ts ();
          priority;
        } in
        let entry = { rank; info; resolver = r; cancelled = Atomic.make false } in
        t.waiters <- insert_sorted entry t.waiters;
        Admission_queue_metrics.on_enqueue ~keeper_name ~cascade_name;
        `Wait (p, entry)
      ))
  in
  match action with
  | `Got_slot ->
    Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms:0;
    ()
  | `Wait (p, entry) ->
    let enqueue_ts = entry.info.enqueue_ts in
    (try
       Eio.Promise.await p;
       let wait_ms =
         int_of_float ((now_ts () -. enqueue_ts) *. 1000.0)
       in
       Admission_queue_metrics.on_dequeue ~keeper_name ~cascade_name;
       Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms
     with exn ->
       Atomic.set entry.cancelled true;
       Admission_queue_metrics.on_dequeue ~keeper_name ~cascade_name;
       Admission_queue_metrics.on_cancelled ~keeper_name ~cascade_name;
       (* If release already resolved our promise, the slot was handed
          to us but we are being cancelled. Release it back. *)
       if Eio.Promise.is_resolved p then
         release_slot t;
       raise exn)

and release_slot t =
  let to_wake =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let rec find_valid = function
        | [] ->
          t.active <- t.active - 1;
          None
        | entry :: rest ->
          if Atomic.get entry.cancelled then
            find_valid rest
          else (
            t.waiters <- rest;
            Some entry
          )
      in
      find_valid t.waiters)
  in
  match to_wake with
  | Some entry -> Eio.Promise.resolve entry.resolver ()
  | None -> ()

(* ── Public API ────────────────────────────────────────── *)

let with_permit ~priority ~keeper_name ~cascade_name f =
  acquire ~priority ~keeper_name ~cascade_name global;
  Fun.protect f
    ~finally:(fun () ->
      Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
      release_slot global)

let try_with_permit ~priority ~keeper_name ~cascade_name f =
  let _resolved = Llm_provider.Request_priority.resolve priority in
  let got =
    Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
      if global.active < global.max_slots then (
        global.active <- global.active + 1;
        true
      ) else
        false)
  in
  if got then (
    Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms:0;
    Some (Fun.protect f
      ~finally:(fun () ->
        Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
        release_slot global)))
  else
    None

let snapshot () =
  Eio.Mutex.use_ro global.mutex (fun () ->
    { max_concurrent = global.max_slots;
      active = global.active;
      available = max 0 (global.max_slots - global.active);
      queue_depth = List.length global.waiters;
      waiters = List.map (fun (w : waiter) -> w.info) global.waiters })

let snapshot_json () =
  let s = snapshot () in
  let now = now_ts () in
  `Assoc [
    ("max_concurrent", `Int s.max_concurrent);
    ("active", `Int s.active);
    ("available", `Int s.available);
    ("queue_depth", `Int s.queue_depth);
    ("waiters", `List (List.map (fun (w : waiter_info) ->
      `Assoc [
        ("keeper_name", `String w.keeper_name);
        ("cascade_name", `String w.cascade_name);
        ("priority", `String (Llm_provider.Request_priority.to_string w.priority));
        ("wait_seconds", `Float (now -. w.enqueue_ts));
      ]) s.waiters));
  ]

let set_max_concurrent n =
  if n < 1 then
    invalid_arg
      (Printf.sprintf "Admission_queue.set_max_concurrent: must be >= 1, got %d" n);
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.max_slots <- n)

let max_concurrent () = global.max_slots

(* For test access — reset queue state between tests. *)
let reset_for_test ~max_slots =
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.max_slots <- max_slots;
    global.active <- 0;
    global.waiters <- [])
