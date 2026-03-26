(** Dashboard response cache — time-bounded memoization with stale-while-revalidate.

    Two time thresholds per entry:
    - [expires_at]: fresh data deadline.  Before this, return immediately.
    - [stale_until]: grace period after expiry.  Return stale data instantly
      while a background fiber recomputes.  After [stale_until], block on
      recomputation.

    Per-key locking prevents deadlock from nested [get_or_compute] calls while
    still guarding against stampede (multiple fibers computing the same key).

    The single [Eio.Mutex] guards only [Hashtbl] access.  [compute] functions
    execute without holding the lock, so nested calls for different keys
    proceed without blocking.

    When no stale data is available, waiters use a bounded poll-retry loop
    instead of [Condition.await] inside [Mutex.use_rw ~protect:true] to
    prevent the cancellation-immune deadlock: [protect:true] disables Eio
    cancellation, so a waiter blocked on [Condition.await] inside that
    section can never be timed out or cancelled.  The poll loop sleeps
    outside the mutex, remaining cancellable.

    Ownership: each compute action carries its [cond] as an ownership
    token.  Before writing back, the fiber checks via physical equality
    that the table still holds its [cond].  This prevents an evicted
    fiber from clobbering a replacement slot. *)

type entry = {
  value : Yojson.Safe.t;
  expires_at : float;
  stale_until : float;
}

type slot =
  | Ready of entry
  | Computing of { cond : Eio.Condition.t; started_at : float; stale : Yojson.Safe.t option }

let table : (string, slot) Hashtbl.t = Hashtbl.create 16
let mu = Eio.Mutex.create ()
(** Background revalidation switch — must be set via [set_sw] before
    stale-while-revalidate can fork background fibers. *)
let _bg_sw : Eio.Switch.t option ref = ref None

type any_clock = Clock : _ Eio.Time.clock -> any_clock

let clock_ref : any_clock option ref = ref None

let set_clock clk = clock_ref := Some (Clock clk)

let set_sw sw = _bg_sw := Some sw

let now () = Time_compat.now ()

(** Default stale grace multiplier: stale data is served for [ttl * stale_factor]
    seconds after expiry while recomputation runs in the background.
    Set high (10x) because Eio cooperative scheduling inflates wall-clock
    time for compute-heavy endpoints (e.g. /execution), making frequent
    recomputation expensive.  A large stale window ensures callers almost
    always receive instant stale responses while background revalidation
    runs. *)
let stale_factor = 10.0

(** Maximum seconds a waiter will poll for a [Computing] slot before evicting
    it and recomputing.  Must exceed the longest endpoint timeout (currently
    120s for /execution) to avoid evicting slots mid-compute.  Bounds
    worst-case latency to [max_wait_sec + compute_time]. *)
let max_wait_sec = 130.0

(** Eio path: per-key locking with stampede protection + stale-while-revalidate.

    Three cases on cache lookup:
    1. Fresh ([now < expires_at]) — return immediately.
    2. Stale ([expires_at <= now < stale_until]) — return stale value, kick off
       background recompute if not already running.
    3. Expired ([now >= stale_until]) or absent — block on compute.

    When no stale data is available (case 3 or [Computing { stale = None }]),
    waiters use bounded poll-retry instead of [Condition.await] to avoid
    the cancellation-immune deadlock.  If a [Computing] slot is stuck beyond
    [max_wait_sec], waiters evict it and recompute.

    Waiter budget is reset when the watched [Computing] slot is replaced
    (detected via [cond] physical identity change), preventing cascading
    eviction of fresh slots. *)
let get_or_compute_eio key ~ttl compute =
  let stale_grace = ttl *. stale_factor in
  let rec try_get ~waited ~watching_cond =
    let action =
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        match Hashtbl.find_opt table key with
        | Some (Ready entry) when entry.expires_at > now () ->
          (* Case 1: fresh *)
          `Hit entry.value
        | Some (Ready entry) when entry.stale_until > now () ->
          (* Case 2: stale but within grace — serve stale, trigger bg recompute *)
          let cond = Eio.Condition.create () in
          Hashtbl.replace table key
            (Computing { cond; started_at = now (); stale = Some entry.value });
          `Stale (entry.value, cond)
        | Some (Computing { stale = Some stale_value; _ }) ->
          (* Another fiber is already recomputing; return stale *)
          `Hit stale_value
        | Some (Computing { cond; started_at; stale = None }) ->
          (* Computing with no stale data — poll-retry with bounded wait.
             Reset waiter budget when the slot was replaced (different cond)
             to prevent cascading eviction of fresh slots. *)
          let waited =
            match watching_cond with
            | Some c when c != cond -> 0.0
            | _ -> waited
          in
          let elapsed = now () -. started_at in
          if elapsed > max_wait_sec || waited > max_wait_sec then begin
            Log.Dashboard.warn "cache: evicting stale Computing slot for %s (%.1fs elapsed)"
              key elapsed;
            Hashtbl.remove table key;
            Eio.Condition.broadcast cond;
            (* Fix D: cooldown after timeout eviction.
               Instead of immediately starting a new Compute (which causes thrashing),
               insert a short-lived Ready entry with error JSON.  Next request after
               the cooldown_ttl will trigger a fresh compute. *)
            let cooldown_ttl = 15.0 in
            let ts = now () in
            let error_value = `Assoc [
              ("error", `String "computation_cooldown");
              ("message", `String (Printf.sprintf
                "Dashboard %s timed out (%.0fs). Cooling down for %.0fs."
                key elapsed cooldown_ttl));
              ("generated_at", `String (Types.now_iso ()));
            ] in
            Hashtbl.replace table key
              (Ready { value = error_value;
                       expires_at = ts +. cooldown_ttl;
                       stale_until = ts +. cooldown_ttl });
            `Hit error_value
          end else
            `Wait cond
        | _ ->
          (* Case 3: expired or absent — must compute *)
          let cond = Eio.Condition.create () in
          Hashtbl.replace table key
            (Computing { cond; started_at = now (); stale = None });
          `Compute cond)
    in
    match action with
    | `Hit v -> v
    | `Wait slot_cond ->
      (* Sleep briefly outside the mutex — this IS cancellable since
         Eio.Time.sleep is a cooperative suspension point. *)
      (match !clock_ref with
       | Some (Clock clk) -> Eio.Time.sleep clk 0.5
       | None -> Eio.Fiber.yield ());
      try_get ~waited:(waited +. 0.5) ~watching_cond:(Some slot_cond)
    | `Stale (stale_value, cond) ->
      let do_bg_compute () =
        match compute () with
        | value ->
          let ts = now () in
          Eio.Mutex.use_rw ~protect:true mu (fun () ->
            (* Only write back if we still own the slot *)
            match Hashtbl.find_opt table key with
            | Some (Computing { cond = c; _ }) when c == cond ->
              Hashtbl.replace table key
                (Ready { value; expires_at = ts +. ttl;
                         stale_until = ts +. ttl +. stale_grace })
            | _ ->
              Log.Dashboard.info "cache: bg-revalidate discarded for %s (slot replaced)"
                key);
          Eio.Condition.broadcast cond
        | exception exn ->
          Log.Dashboard.warn "cache bg-revalidate failed (%s): %s"
            key (Printexc.to_string exn);
          Eio.Mutex.use_rw ~protect:true mu (fun () ->
            match Hashtbl.find_opt table key with
            | Some (Computing { cond = c; _ }) when c == cond ->
              (* Restore stale entry so next request can still serve it *)
              let ts = now () in
              Hashtbl.replace table key
                (Ready { value = stale_value;
                         expires_at = ts;
                         stale_until = ts +. stale_grace })
            | _ -> ());
          Eio.Condition.broadcast cond
      in
      (* Background revalidation: fork on the main domain's switch if available.
         When called from Executor_pool (different domain), fork would raise
         "Switch accessed from wrong domain!" — fall back to inline compute. *)
      (match !_bg_sw with
       | Some sw ->
           (try Eio.Fiber.fork ~sw (fun () ->
              try do_bg_compute ()
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Dashboard.error "cache revalidation failed: %s"
                  (Printexc.to_string exn))
            with Invalid_argument _ -> do_bg_compute ())
       | None -> do_bg_compute ());
      stale_value
    | `Compute cond ->
      (match compute () with
       | value ->
         let ts = now () in
         Eio.Mutex.use_rw ~protect:true mu (fun () ->
           (* Only write back if we still own the slot *)
           match Hashtbl.find_opt table key with
           | Some (Computing { cond = c; _ }) when c == cond ->
             Hashtbl.replace table key
               (Ready { value; expires_at = ts +. ttl;
                        stale_until = ts +. ttl +. stale_grace })
           | _ ->
             Log.Dashboard.info "cache: compute result discarded for %s (slot replaced)"
               key);
         Eio.Condition.broadcast cond;
         value
       | exception exn ->
         let bt = Printexc.get_raw_backtrace () in
         Eio.Mutex.use_rw ~protect:true mu (fun () ->
           (* Only remove if we still own the slot *)
           match Hashtbl.find_opt table key with
           | Some (Computing { cond = c; _ }) when c == cond ->
             Hashtbl.remove table key
           | _ -> ());
         Eio.Condition.broadcast cond;
         Printexc.raise_with_backtrace exn bt)
  in
  try_get ~waited:0.0 ~watching_cond:None

(** Non-Eio fallback: no mutex, no concurrency. *)
let get_or_compute_simple key ~ttl compute =
  let stale_grace = ttl *. stale_factor in
  match Hashtbl.find_opt table key with
  | Some (Ready entry) when entry.expires_at > now () -> entry.value
  | Some (Ready entry) when entry.stale_until > now () ->
    (* Stale but usable — recompute inline (no fibers available) *)
    let value =
      try compute ()
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Dashboard.warn "stale cache recompute failed for %s: %s"
          key (Printexc.to_string exn);
        entry.value
    in
    let ts = now () in
    Hashtbl.replace table key
      (Ready { value; expires_at = ts +. ttl;
               stale_until = ts +. ttl +. stale_grace });
    value
  | _ ->
    let value = compute () in
    let ts = now () in
    Hashtbl.replace table key
      (Ready { value; expires_at = ts +. ttl;
               stale_until = ts +. ttl +. stale_grace });
    value

let timeout_error_json key timeout_sec =
  `Assoc [
    ("error", `String "computation_timeout");
    ("message", `String (Printf.sprintf "Dashboard %s timed out after %.0fs" key timeout_sec));
    ("generated_at", `String (Types.now_iso ()));
  ]

let get_or_compute key ~ttl compute =
  if Eio_guard.is_ready () then get_or_compute_eio key ~ttl compute
  else get_or_compute_simple key ~ttl compute

(** Compute with Eio timeout.  Stale-while-revalidate applies here too:
    if a stale value exists and the recompute times out, the stale value
    was already returned to the caller by [get_or_compute_eio].

    On timeout the inner compute raises [Compute_timeout] so that
    [get_or_compute_eio]'s exception handler preserves the stale value
    in the background-revalidation path (instead of overwriting it with
    error JSON).  The outer [try] catches the exception for the no-stale
    path and returns [timeout_error_json] to the caller without caching
    it. *)

exception Compute_timeout of string

let get_or_compute_with_timeout key ~ttl ~clock ~timeout_sec compute =
  try
    get_or_compute key ~ttl (fun () ->
      match
        Eio.Time.with_timeout clock timeout_sec (fun () ->
          Ok (compute ()))
      with
      | Ok value -> value
      | Error `Timeout ->
        Log.Dashboard.warn "cache compute timeout: %s (%.0fs)" key timeout_sec;
        raise (Compute_timeout key))
  with Compute_timeout k ->
    timeout_error_json k timeout_sec

let invalidate key =
  if Eio_guard.is_ready () then
    let cond_opt =
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        let c =
          match Hashtbl.find_opt table key with
          | Some (Computing { cond; _ }) -> Some cond
          | _ -> None
        in
        Hashtbl.remove table key;
        c)
    in
    Option.iter Eio.Condition.broadcast cond_opt
  else Hashtbl.remove table key

let invalidate_all () =
  if Eio_guard.is_ready () then
    let conds =
      Eio.Mutex.use_rw ~protect:true mu (fun () ->
        let cs =
          Hashtbl.fold
            (fun _key slot acc ->
              match slot with Computing { cond; _ } -> cond :: acc | _ -> acc)
            table []
        in
        Hashtbl.clear table;
        cs)
    in
    List.iter Eio.Condition.broadcast conds
  else Hashtbl.clear table

let stats () =
  let compute () =
    let now_ts = now () in
    let total = Hashtbl.length table in
    let fresh =
      Hashtbl.fold
        (fun _key slot count ->
          match slot with
          | Ready entry when entry.expires_at > now_ts -> count + 1
          | _ -> count)
        table 0
    in
    let stale =
      Hashtbl.fold
        (fun _key slot count ->
          match slot with
          | Ready entry when entry.expires_at <= now_ts && entry.stale_until > now_ts ->
            count + 1
          | _ -> count)
        table 0
    in
    let computing =
      Hashtbl.fold
        (fun _key slot count ->
          match slot with Computing _ -> count + 1 | _ -> count)
        table 0
    in
    `Assoc
      [
        ("entries", `Int total);
        ("fresh", `Int fresh);
        ("stale", `Int stale);
        ("computing", `Int computing);
        ("expired", `Int (total - fresh - stale - computing));
      ]
  in
  if Eio_guard.is_ready () then Eio.Mutex.use_rw ~protect:true mu compute
  else compute ()
