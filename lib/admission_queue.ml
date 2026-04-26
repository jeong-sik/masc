(** Admission_queue — MASC-layer priority admission queue for inference calls.

    Mirrors OAS Slot_scheduler design (priority sorted waiter list,
    Eio.Promise blocking, Atomic cancel flag) at the MASC layer with
    MASC-visible waiter metadata for observability.

    @since 3.0.0 *)

(* ── Types ─────────────────────────────────────────────── *)

type waiter_info =
  { keeper_name : string
  ; cascade_name : string
  ; enqueue_ts : float
  ; priority : Llm_provider.Request_priority.t
  }

type snapshot =
  { max_concurrent : int
  ; active : int
  ; available : int
  ; queue_depth : int
  ; waiters : waiter_info list
  }

type waiter =
  { rank : int
  ; info : waiter_info
  ; resolver : unit Eio.Promise.u
  ; cancelled : bool Atomic.t
  }

type t =
  { mutable max_slots : int
  ; mutable active : int
  ; mutable waiters : waiter list
  ; mutex : Eio.Mutex.t
  }

(* ── Sorted Insertion ──────────────────────────────────── *)

(** Insert waiter in priority order (lower rank = higher priority = front).
    Stable: equal-rank waiters maintain FIFO order. *)
let insert_sorted entry ws =
  let rec go acc = function
    | [] -> List.rev (entry :: acc)
    | w :: rest as tail ->
      if entry.rank <= w.rank
      then List.rev_append acc (entry :: tail)
      else go (w :: acc) rest
  in
  go [] ws
;;

(* ── Core Queue ────────────────────────────────────────── *)

let initial_max_concurrent_of_env getenv =
  let parse_int raw =
    Option.bind (getenv raw) (fun value -> int_of_string_opt (String.trim value))
  in
  match parse_int "MASC_ADMISSION_MAX_CONCURRENT" with
  | Some n -> max 1 n
  | None ->
    (* Default 3: with_permit is now passthrough (provider throttle
         belongs in OAS cascade, not MASC).  This value is only used
         for snapshot reporting; it does not gate anything. *)
    3
;;

let global : t =
  { max_slots = initial_max_concurrent_of_env Sys.getenv_opt
  ; active = 0
  ; waiters = []
  ; mutex = Eio.Mutex.create ()
  }
;;

let () = Admission_queue_metrics.set_max_concurrent global.max_slots
let now_ts () = Unix.gettimeofday ()
let wait_ms_since enqueue_ts = int_of_float ((now_ts () -. enqueue_ts) *. 1000.0)

(* ── Public API ────────────────────────────────────────── *)

let check_host_resources ~keeper_name =
  let fd_count = Prometheus.approximate_open_fd_count () in
  let threshold = Prometheus.fd_warn_threshold in
  if fd_count >= threshold * 9 / 10
  then (
    let msg = Printf.sprintf "fd count %d >= 90%% of threshold %d" fd_count threshold in
    Log.Misc.warn "admission rejected for %s: %s" keeper_name msg;
    Error (`Host_resource_saturated msg))
  else Ok ()
;;

let with_permit ?wait_timeout_sec:_ ~priority:_ ~keeper_name ~cascade_name f =
  (* SSOT: every admission_queue entry point canonicalizes cascade_name
     so metrics/structs never see drift values. *)
  let cascade_name = Keeper_cascade_profile.canonicalize cascade_name in
  match check_host_resources ~keeper_name with
  | Error _ as e -> e
  | Ok () ->
    (* Passthrough: provider-level throttling belongs in OAS (cascade),
         not in MASC.  The cascade distributes requests across providers
         and handles 429/timeout by falling to the next provider.
         Gating here starves cloud-routed keepers behind a serial local
         decode and cannot express per-provider capacity.
         Metric observation tracks real inflight even though gating is off. *)
    Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms:0;
    (match f () with
     | result ->
       Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
       Ok result
     | exception exn ->
       Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
       raise exn)
;;

let try_with_permit ~priority:_ ~keeper_name ~cascade_name f =
  match check_host_resources ~keeper_name with
  | Error _ -> None
  | Ok () ->
    Admission_queue_metrics.on_acquire ~keeper_name ~cascade_name ~wait_ms:0;
    (match f () with
     | result ->
       Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
       Some result
     | exception exn ->
       Admission_queue_metrics.on_release ~keeper_name ~cascade_name;
       raise exn)
;;

let snapshot () =
  Eio.Mutex.use_ro global.mutex (fun () ->
    { max_concurrent = global.max_slots
    ; active = global.active
    ; available = max 0 (global.max_slots - global.active)
    ; queue_depth = List.length global.waiters
    ; waiters = List.map (fun (w : waiter) -> w.info) global.waiters
    })
;;

let snapshot_json () =
  let s = snapshot () in
  let now = now_ts () in
  `Assoc
    [ "max_concurrent", `Int s.max_concurrent
    ; "active", `Int s.active
    ; "available", `Int s.available
    ; "queue_depth", `Int s.queue_depth
    ; ( "waiters"
      , `List
          (List.map
             (fun (w : waiter_info) ->
                `Assoc
                  [ "keeper_name", `String w.keeper_name
                  ; "cascade_name", `String w.cascade_name
                  ; ( "priority"
                    , `String (Llm_provider.Request_priority.to_string w.priority) )
                  ; "wait_seconds", `Float (now -. w.enqueue_ts)
                  ])
             s.waiters) )
    ]
;;

let set_max_concurrent n =
  if n < 1
  then
    invalid_arg
      (Printf.sprintf "Admission_queue.set_max_concurrent: must be >= 1, got %d" n);
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () -> global.max_slots <- n);
  Admission_queue_metrics.set_max_concurrent n
;;

let max_concurrent () = global.max_slots

(* For test access — reset queue state between tests. *)
let reset_for_test ~max_slots =
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.max_slots <- max_slots;
    global.active <- 0;
    global.waiters <- []);
  Admission_queue_metrics.set_max_concurrent max_slots
;;
