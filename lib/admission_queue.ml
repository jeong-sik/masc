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

exception Wait_timeout of int

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

exception Host_resource_saturated of string

(* ── Core Queue ────────────────────────────────────────── *)

let initial_max_concurrent_of_env getenv =
  let parse_int raw =
    Option.bind (getenv raw) (fun value ->
      int_of_string_opt (String.trim value))
  in
  match parse_int "MASC_ADMISSION_MAX_CONCURRENT" with
  | Some n -> max 1 n
  | None ->
      (* Default 3: with_permit is now passthrough (provider throttle
         belongs in OAS cascade, not MASC).  This value is only used
         for snapshot reporting; it does not gate anything. *)
      3

let global : t = {
  max_slots = initial_max_concurrent_of_env Sys.getenv_opt;
  active = 0;
  waiters = [];
  mutex = Eio.Mutex.create ();
}

let () = Admission_queue_metrics.set_max_concurrent global.max_slots

let now_ts () = Unix.gettimeofday ()
let wait_ms_since enqueue_ts = int_of_float ((now_ts () -. enqueue_ts) *. 1000.0)

let rec _acquire ?wait_timeout_sec ~priority ~keeper_name ~cascade_name t =
  (* Normalize at the gate: any cascade name stored in the admission info
     record or forwarded to metrics passes through the SSOT canonicalizer,
     so downstream consumers never see drift/ghost values. *)
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
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
    let cancel_wait exn =
      Atomic.set entry.cancelled true;
      Admission_queue_metrics.on_dequeue ~keeper_name ~cascade_name;
      Admission_queue_metrics.on_cancelled ~keeper_name ~cascade_name;
      (* If release already resolved our promise, the slot was handed
         to us but we are being cancelled. Release it back. *)
      if Eio.Promise.is_resolved p then
        _release_slot t;
      raise exn
    in
    (try
       (match wait_timeout_sec with
        | Some timeout_sec ->
            (match Eio_context.get_clock_opt () with
             | Some clock ->
                 Eio.Time.with_timeout_exn clock timeout_sec
                   (fun () -> Eio.Promise.await p)
             | None ->
                 Eio.Promise.await p)
        | None -> Eio.Promise.await p);
       let wait_ms = wait_ms_since enqueue_ts in
       Admission_queue_metrics.on_dequeue ~keeper_name ~cascade_name;
       Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms
     with
     | Eio.Time.Timeout ->
         cancel_wait (Wait_timeout (wait_ms_since enqueue_ts))
     | exn ->
         cancel_wait exn)

and _release_slot t =
  let to_wake =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      let rec find_valid acc = function
        | [] ->
          t.waiters <- List.rev acc;
          t.active <- t.active - 1;
          None
        | entry :: rest ->
          if Atomic.get entry.cancelled then
            find_valid acc rest
          else (
            t.waiters <- List.rev_append acc rest;
            Some entry
          )
      in
      find_valid [] t.waiters)
  in
  match to_wake with
  | Some entry -> Eio.Promise.resolve entry.resolver ()
  | None -> ()

(* ── Public API ────────────────────────────────────────── *)

let check_host_resources ~keeper_name =
  let fd_count = Prometheus.approximate_open_fd_count () in
  let threshold = Prometheus.fd_warn_threshold in
  if fd_count >= threshold * 9 / 10 then begin
    let msg =
      Printf.sprintf "fd count %d >= 90%% of threshold %d" fd_count threshold
    in
    Log.Misc.warn "admission rejected for %s: %s" keeper_name msg;
    raise (Host_resource_saturated msg)
  end

let with_permit ?wait_timeout_sec:_ ~priority:_ ~keeper_name ~cascade_name f =
  (* SSOT: every admission_queue entry point canonicalizes cascade_name
     so metrics/structs never see drift values. *)
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  check_host_resources ~keeper_name;
  (* Passthrough: provider-level throttling belongs in OAS (cascade),
     not in MASC.  The cascade distributes requests across providers
     and handles 429/timeout by falling to the next provider.
     Gating here starves cloud-routed keepers behind a serial local
     decode and cannot express per-provider capacity.
     Metric observation tracks real inflight even though gating is off. *)
  Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms:0;
  match f () with
  | result ->
    Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
    result
  | exception exn ->
    Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
    raise exn

let try_with_permit ~priority:_ ~keeper_name ~cascade_name f =
  check_host_resources ~keeper_name;
  Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms:0;
  match f () with
  | result ->
    Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
    Some result
  | exception exn ->
    Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
    raise exn

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
    global.max_slots <- n);
  Admission_queue_metrics.set_max_concurrent n

let max_concurrent () = global.max_slots

(* For test access — reset queue state between tests. *)
let reset_for_test ~max_slots =
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.max_slots <- max_slots;
    global.active <- 0;
    global.waiters <- []);
  Admission_queue_metrics.set_max_concurrent max_slots
