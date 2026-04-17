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

module SMap = Map.Make(String)

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let new_val = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then ()
  else atomic_update atomic f

let token_counter = Atomic.make 0
let next_token () = Atomic.fetch_and_add token_counter 1

type entry = {
  value : Yojson.Safe.t;
  expires_at : float;
  stale_until : float;
}

type slot =
  | Ready of entry
  | Computing of { token : int; started_at : float; stale : Yojson.Safe.t option }

let table : slot SMap.t Atomic.t = Atomic.make SMap.empty

(** Maximum cache entries before eviction kicks in.
    Evicts expired entries first, then oldest stale entries. *)
let max_entries =
  match Sys.getenv_opt "MASC_DASHBOARD_CACHE_MAX_ENTRIES" with
  | Some s -> (match int_of_string_opt (String.trim s) with Some v -> max 16 (min 512 v) | None -> 64)
  | None -> 64

(** Evict one expired or stale entry when table exceeds max_entries.
    Must be called inside the mutex-guarded section. *)
let maybe_evict map =
  if SMap.cardinal map > max_entries then begin
    let now_ts = Time_compat.now () in
    let victim = ref None in
    SMap.iter (fun key slot ->
      match slot with
      | Ready entry when entry.stale_until <= now_ts ->
          (match !victim with
           | Some (_, true) -> ()
           | _ -> victim := Some (key, true))
      | Ready entry when entry.expires_at <= now_ts ->
          (match !victim with
           | Some (_, true) -> ()
           | _ -> victim := Some (key, false))
      | _ -> ()
    ) map;
    match !victim with
    | Some (key, _) -> SMap.remove key map
    | None -> map
  end else map

let now () = Time_compat.now ()

(** Default stale grace multiplier: stale data is served for [ttl * stale_factor]
    seconds after expiry while recomputation runs in the background.
    Reduced from 10x to 3x — the 10x factor was masking slow compute
    by holding stale data for 22 minutes. With O(n+ops) tree index and
    adaptive refresh intervals, compute is faster so shorter grace is safe. *)
let stale_factor = 3.0

(** Backoff multiplier for stale_grace on bg-revalidation failure.
    Extends the stale window to reduce retry pressure when compute
    repeatedly fails.  2.0 means the second attempt waits twice the
    normal stale_grace before retrying.  #5402 *)
let bg_revalidate_backoff_factor = 2.0

exception Compute_timeout of string * bool

(** Maximum seconds a waiter will poll for a [Computing] slot before evicting
    it and recomputing.

    This must stay at or above the largest caller wait budget used with
    [get_or_compute_with_timeout]; otherwise concurrent waiters can evict an
    active [Computing { stale = None }] slot before their own wait budget is
    exhausted, causing early failures and duplicate recomputation.  Keep this
    above the current 120s caller budget. *)
let max_wait_sec = 130.0
let wait_poll_interval_sec = 0.25

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
let get_or_compute_eio ?wait_timeout_sec key ~ttl compute =
  let stale_grace = ttl *. stale_factor in
  let rec try_get ~waited ~watching_token =
    let action = ref None in
    atomic_update table (fun map ->
      let map = maybe_evict map in
      match SMap.find_opt key map with
      | Some (Ready entry) when entry.expires_at > now () ->
        action := Some (`Hit entry.value);
        map
      | Some (Ready entry) when entry.stale_until > now () ->
        let token = next_token () in
        action := Some (`Stale (entry.value, token));
        SMap.add key (Computing { token; started_at = now (); stale = Some entry.value }) map
      | Some (Computing { stale = Some stale_value; _ }) ->
        action := Some (`Hit stale_value);
        map
      | Some (Computing { token; started_at; stale = None }) ->
        let waited =
          match watching_token with
          | Some t when t <> token -> 0.0
          | _ -> waited
        in
        let elapsed = now () -. started_at in
        let timed_out_waiter =
          match wait_timeout_sec with
          | Some timeout_sec -> waited >= timeout_sec
          | None -> false
        in
        if timed_out_waiter then begin
          action := Some `Timed_out;
          map
        end else if elapsed > max_wait_sec || waited > max_wait_sec then begin
          Log.Dashboard.warn "cache: evicting stale Computing slot for %s (%.1fs elapsed)" key elapsed;
          action := Some `Retry;
          SMap.remove key map
        end else begin
          action := Some (`Wait token);
          map
        end
      | Some (Ready _) | None ->
        let token = next_token () in
        action := Some (`Compute token);
        SMap.add key (Computing { token; started_at = now (); stale = None }) map
    );
    match Option.get !action with
    | `Hit v -> v
    | `Timed_out -> raise (Compute_timeout (key, true))
    | `Wait token ->
      Time_compat.sleep wait_poll_interval_sec;
      try_get ~waited:(waited +. wait_poll_interval_sec) ~watching_token:(Some token)
    | `Stale (stale_value, token) ->
      let do_bg_compute () =
        match compute () with
        | value ->
          let ts = now () in
          atomic_update table (fun map ->
            match SMap.find_opt key map with
            | Some (Computing { token = c; _ }) when c = token ->
              SMap.add key (Ready { value; expires_at = ts +. ttl; stale_until = ts +. ttl +. stale_grace }) map
            | _ ->
              Log.Dashboard.info "cache: bg-revalidate discarded for %s (slot replaced)" key;
              map
          )
        | exception exn ->
          (match exn with
           | Compute_timeout _ -> ()
           | _ -> Log.Dashboard.warn "cache bg-revalidate failed (%s): %s" key (Printexc.to_string exn));
          atomic_update table (fun map ->
            match SMap.find_opt key map with
            | Some (Computing { token = c; _ }) when c = token ->
              let ts = now () in
              let backoff_grace = stale_grace *. bg_revalidate_backoff_factor in
              SMap.add key (Ready { value = stale_value; expires_at = ts; stale_until = ts +. backoff_grace }) map
            | _ -> map
          )
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           (try Eio.Fiber.fork ~sw (fun () ->
              try do_bg_compute ()
              with
              | Eio.Cancel.Cancelled _ as e ->
                atomic_update table (fun map ->
                  match SMap.find_opt key map with
                  | Some (Computing { token = c; _ }) when c = token ->
                    let ts = now () in
                    let backoff_grace = stale_grace *. bg_revalidate_backoff_factor in
                    SMap.add key (Ready { value = stale_value; expires_at = ts; stale_until = ts +. backoff_grace }) map
                  | _ -> map
                );
                raise e)
            with Eio.Cancel.Cancelled _ -> ())
       | None ->
           Log.Dashboard.warn "cache: no switch for background revalidation, computing inline";
           do_bg_compute ());
      stale_value
    | `Compute token ->
      let result_ref = ref None in
      let run_compute () =
        try result_ref := Some (Ok (compute ()))
        with exn -> result_ref := Some (Error exn)
      in
      (match Eio_context.get_clock_opt () with
       | Some clock ->
           let compute_done = ref false in
           Eio.Fiber.first
             (fun () ->
                run_compute ();
                compute_done := true)
             (fun () ->
                Eio.Time.sleep clock max_wait_sec;
                if not !compute_done then
                  Log.Dashboard.warn "cache compute timeout: %s (%.0fs)" key max_wait_sec)
       | None ->
           (* Some read-model tests enable Eio without seeding the global
              Eio_context clock. In that harness, run inline without the
              watchdog rather than hard-failing. *)
           run_compute ());
      let ts = now () in
      (match !result_ref with
       | Some (Ok value) ->
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; _ }) when c = token ->
               SMap.add key (Ready { value; expires_at = ts +. ttl; stale_until = ts +. ttl +. stale_grace }) map
             | _ ->
               Log.Dashboard.info "cache: compute result discarded for %s (slot replaced)" key;
               map
           );
           value
       | Some (Error exn) ->
           Log.Dashboard.error "cache revalidation failed: %s" (Printexc.to_string exn);
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; _ }) when c = token -> SMap.remove key map
             | _ -> map
           );
           raise exn
       | None ->
           let fallback_val = ref None in
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; stale; _ }) when c = token ->
                 (match stale with
                  | Some s ->
                      fallback_val := Some s;
                      let cooldown = { value = s; expires_at = ts +. 5.0; stale_until = ts +. 10.0 } in
                      SMap.add key (Ready cooldown) map
                  | None ->
                      let err_json = `Assoc [("error", `String "Compute timeout");
                                             ("timeout_sec", `Float max_wait_sec);
                                             ("key", `String key)] in
                      fallback_val := Some err_json;
                      let cooldown = { value = err_json; expires_at = ts +. 5.0; stale_until = ts +. 5.0 } in
                      SMap.add key (Ready cooldown) map)
             | _ -> map
           );
           (match !fallback_val with
            | Some v -> v
            | None -> `Assoc [("error", `String "Compute timeout")]))
    | `Retry -> try_get ~waited ~watching_token
  in
  try_get ~waited:0.0 ~watching_token:None

let get_or_compute_simple key ~ttl compute =
  let ts = now () in
  let stale_grace = ttl *. stale_factor in
  let action = ref None in
  atomic_update table (fun map ->
    let map = maybe_evict map in
    match SMap.find_opt key map with
    | Some (Ready entry) when entry.stale_until > ts ->
      action := Some (`Hit entry.value);
      map
    | _ ->
      let token = next_token () in
      action := Some (`Compute token);
      SMap.add key (Computing { token; started_at = ts; stale = None }) map
  );
  match Option.get !action with
  | `Hit v -> v
  | `Compute token ->
    (match compute () with
     | value ->
       let ts_after = now () in
       atomic_update table (fun map ->
         match SMap.find_opt key map with
         | Some (Computing { token = c; _ }) when c = token ->
           SMap.add key (Ready { value; expires_at = ts_after +. ttl; stale_until = ts_after +. ttl +. stale_grace }) map
         | _ -> map
       );
       value
     | exception exn ->
       atomic_update table (fun map ->
         match SMap.find_opt key map with
         | Some (Computing { token = c; _ }) when c = token -> SMap.remove key map
         | _ -> map
       );
       raise exn)

let get_or_compute key ~ttl compute =
  if Eio_guard.is_ready () then get_or_compute_eio key ~ttl compute
  else get_or_compute_simple key ~ttl compute

let timeout_error_json ?(waiting = false) key timeout_sec =
  let message =
    if waiting then
      Printf.sprintf
        "Dashboard %s timed out after %.0fs waiting for an in-flight computation"
        key timeout_sec
    else
      Printf.sprintf "Dashboard %s timed out after %.0fs" key timeout_sec
  in
  `Assoc
    [
      ("error", `String "computation_timeout");
      ("message", `String message);
      ("generated_at", `String (Types.now_iso ()));
      ("timeout_kind", `String (if waiting then "waiter" else "owner"));
      ("timeout_sec", `Float timeout_sec);
      ("key", `String key);
    ]

let get_or_compute_with_timeout key ~ttl ~clock ~timeout_sec compute =
  try
    if Eio_guard.is_ready () then
      get_or_compute_eio ~wait_timeout_sec:timeout_sec key ~ttl (fun () ->
        match
          Eio.Time.with_timeout clock timeout_sec (fun () ->
            Ok (compute ()))
        with
        | Ok value -> value
        | Error `Timeout ->
          Log.Dashboard.warn "cache compute timeout: %s (%.0fs)" key timeout_sec;
          raise (Compute_timeout (key, false)))
    else
      get_or_compute_simple key ~ttl (fun () ->
        match
          Eio.Time.with_timeout clock timeout_sec (fun () ->
            Ok (compute ()))
        with
        | Ok value -> value
        | Error `Timeout ->
          Log.Dashboard.warn "cache compute timeout: %s (%.0fs)" key timeout_sec;
          raise (Compute_timeout (key, false)))
  with
  | Compute_timeout (key, waiting) ->
      timeout_error_json ~waiting key timeout_sec

let invalidate key =
  atomic_update table (fun map -> SMap.remove key map)

let invalidate_prefix prefix =
  atomic_update table (fun map ->
    SMap.filter (fun k _ -> not (String.starts_with ~prefix k)) map)

let invalidate_all () =
  Atomic.set table SMap.empty

let stats () =
  let map = Atomic.get table in
  let now_ts = Time_compat.now () in
  let ready_fresh = ref 0 in
  let ready_stale = ref 0 in
  let ready_expired = ref 0 in
  let computing = ref 0 in
  SMap.iter (fun _ v ->
    match v with
    | Ready e ->
        if now_ts <= e.expires_at then
          incr ready_fresh
        else if now_ts <= e.stale_until then
          incr ready_stale
        else
          incr ready_expired
    | Computing _ -> incr computing
  ) map;
  `Assoc [
    ("entries", `Int (SMap.cardinal map));
    ("fresh", `Int !ready_fresh);
    ("stale", `Int !ready_stale);
    ("expired", `Int !ready_expired);
    ("ready_fresh", `Int !ready_fresh);
    ("ready_stale", `Int !ready_stale);
    ("computing", `Int !computing);
    ("max_entries", `Int max_entries);
  ]
