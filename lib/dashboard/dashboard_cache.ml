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

module SMap = Set_util.StringMap

let rec atomic_update atomic f =
  let old_val = Atomic.get atomic in
  let (result, new_val) = f old_val in
  if Atomic.compare_and_set atomic old_val new_val then result
  else atomic_update atomic f

let token_counter = Atomic.make 0
let next_token () = Atomic.fetch_and_add token_counter 1

type cached_payload = {
  json : Yojson.Safe.t;
  raw_json : string;
  etag : string;
}

let etag_hex_chars = 12

let weak_etag_of_string s =
  let hash = Digest.string s |> Digest.to_hex in
  let sub = String.sub hash 0 (min etag_hex_chars (String.length hash)) in
  "W/\"" ^ sub ^ "\""

type entry = {
  value : Yojson.Safe.t;
  raw : (string * string) option Atomic.t;
  expires_at : float;
  stale_until : float;
}

type slot =
  | Ready of entry
  | Computing of { token : int; started_at : float; stale : entry option }

let ensure_raw entry =
  match Atomic.get entry.raw with
  | Some pair -> pair
  | None ->
      let raw_json = Yojson.Safe.to_string entry.value in
      let etag = weak_etag_of_string raw_json in
      let pair = (raw_json, etag) in
      Atomic.set entry.raw (Some pair);
      pair

let payload_of_entry entry =
  let (raw_json, etag) = ensure_raw entry in
  { json = entry.value; raw_json; etag }

let payload_of_json json =
  let raw_json = Yojson.Safe.to_string json in
  let etag = weak_etag_of_string raw_json in
  { json; raw_json; etag }

let table : slot SMap.t Atomic.t = Atomic.make SMap.empty

(** Maximum cache entries before eviction kicks in.
    Evicts expired entries first, then oldest stale entries.

    The previous default (64) is too small for the live dashboard
    surface.  On a running server we observed 41/64 entries (65%)
    occupied by a single [operator:keeper-runtime-trust:compact:...]
    prefix whose key embeds an ISO timestamp — every refresh creates
    a fresh entry and LRU eviction repeatedly purges genuinely hot
    keys like [dashboard.branches], [dashboard.workspace], [board:memory]
    before they can be reused.  Result: hit_ratio ~31% on a workload
    that should be cache-bound.

    Raising the default to 256 keeps the timestamp-keyed entries from
    crowding out the steady-state hot keys.  The env override remains
    available (clamped to [16, 512]) for environments that want to
    tune up or down. *)
let max_entries =
  match Sys.getenv_opt "MASC_DASHBOARD_CACHE_MAX_ENTRIES" with
  | Some s -> (match int_of_string_opt (String.trim s) with Some v -> max 16 (min 512 v) | None -> 256)
  | None -> 256

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
      | Ready _ -> ()
      | Computing _ -> ()
    ) map;
    match !victim with
    | Some (key, _) -> SMap.remove key map
    | None -> map
  end else map

let now () = Time_compat.now ()

type timeout_circuit = {
  consecutive_timeouts : int;
  opened_until : float;
  last_timeout_at : float;
}

let timeout_circuit_threshold = 3
let timeout_circuit_open_sec = 30.0
let timeout_circuit_window_sec = 300.0
let timeout_circuit_table : timeout_circuit SMap.t Atomic.t = Atomic.make SMap.empty

let timeout_circuit_is_open key =
  match SMap.find_opt key (Atomic.get timeout_circuit_table) with
  | Some state when state.opened_until > now () -> true
  | _ -> false

let record_timeout_circuit key =
  let ts = now () in
  let opened =
    atomic_update timeout_circuit_table (fun map ->
      let previous = SMap.find_opt key map in
      let consecutive_timeouts =
        match previous with
        | Some state
          when ts -. state.last_timeout_at <= timeout_circuit_window_sec ->
            state.consecutive_timeouts + 1
        | _ -> 1
      in
      let was_open =
        match previous with
        | Some state when state.opened_until > ts -> true
        | _ -> false
      in
      let opened_until =
        if consecutive_timeouts >= timeout_circuit_threshold then
          ts +. timeout_circuit_open_sec
        else
          0.0
      in
      ( consecutive_timeouts >= timeout_circuit_threshold && not was_open,
        SMap.add key
          { consecutive_timeouts; opened_until; last_timeout_at = ts }
          map ))
  in
  if opened then
    Log.Dashboard.warn
      "cache: opening timeout circuit for %s after repeated no-stale timeouts"
      key

let clear_timeout_circuit key =
  atomic_update timeout_circuit_table (fun map -> ((), SMap.remove key map))

let clear_timeout_circuit_prefix prefix =
  atomic_update timeout_circuit_table (fun map ->
    ((), SMap.filter (fun key _ -> not (String.starts_with ~prefix key)) map))

let clear_timeout_circuit_all () = Atomic.set timeout_circuit_table SMap.empty

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

let is_compute_timeout exn =
  match exn with
  | Compute_timeout _ -> true
  | _ -> false

let should_restore_stale_after_failure exn =
  match exn with
  | Compute_timeout _ -> true
  | Eio.Cancel.Cancelled _ -> true
  | _ -> false

(* The one shape a timed-out compute takes on the wire.

   Every timeout path in this module goes through [timeout_error_json], and the
   only sanctioned reader is [is_timeout_envelope] beside it. Both read
   [timeout_error_code], so changing the wire value cannot leave a reader
   behind — a recognizer that lives in another module and matches the string
   itself drifts silently the moment a producer changes.

   The envelope still travels in-band, as a value indistinguishable from a
   computed payload until a reader checks; #28400 tracks moving it out of band
   and giving it its own HTTP status. *)
let timeout_error_code = "computation_timeout"

type timeout_envelope = {
  key : string;
  timeout_sec : float;
  timeout_kind : string;
  waiting : bool;
}

let timeout_envelope_message { key; timeout_sec; timeout_kind; waiting } =
  match timeout_kind with
  | "circuit_open" ->
    Printf.sprintf "Dashboard %s is failing fast after repeated cache timeouts" key
  | _ when waiting ->
    Printf.sprintf
      "Dashboard %s timed out after %.0fs waiting for an in-flight computation"
      key timeout_sec
  | _ -> Printf.sprintf "Dashboard %s timed out after %.0fs" key timeout_sec

let timeout_envelope_json envelope =
  `Assoc
    [
      ("error", `String timeout_error_code);
      ("message", `String (timeout_envelope_message envelope));
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("timeout_kind", `String envelope.timeout_kind);
      ("timeout_sec", `Float envelope.timeout_sec);
      ("key", `String envelope.key);
    ]

let is_timeout_envelope = function
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String code) -> String.equal code timeout_error_code
     | _ -> false)
  | _ -> false

let timeout_error_json ?timeout_kind ?(waiting = false) key timeout_sec =
  let timeout_kind =
    match timeout_kind with
    | Some timeout_kind -> timeout_kind
    | None -> if waiting then "waiter" else "owner"
  in
  timeout_envelope_json { key; timeout_sec; timeout_kind; waiting }

(** Maximum seconds a waiter will poll for a [Computing] slot before evicting
    it and recomputing.

    Derived from the configured caller timeout budgets so the watchdog
    invariant "watchdog >= largest caller budget" holds by construction.
    Previously hardcoded to 130.0, which silently drifted from caller
    config when env overrides were introduced.  Multiplier N = 8 gives
    headroom so the watchdog is a *floor* protection — under normal
    operation the structural cleanup ([release_on_cancel]) keeps slots
    from ever reaching this ceiling.  An SLO alert on
    [masc_cache_stuck_evictions_total] pages operators if it does fire,
    because that signals [release_on_cancel] is not firing. *)
let max_wait_safety_factor = 8.0

let max_wait_sec () =
  let open Env_config_runtime.Dashboard in
  let longest_caller_budget =
    List.fold_left Float.max 1.0
      [
        execution_timeout_sec;
        execution_trust_timeout_sec;
        briefing_timeout_sec;
        shell_timeout_sec;
        shell_light_timeout_sec;
        shell_prewarm_inner_timeout_sec;
      ]
  in
  longest_caller_budget *. max_wait_safety_factor

let wait_poll_interval_sec = 0.25

(** Deterministic per-key TTL jitter to prevent cache stampede.

    When N entries are inserted at the same wall-clock instant with the
    same TTL (e.g. per-keeper snapshot caches refreshed in a tight loop),
    they expire together and recompute simultaneously — a thundering herd
    proportional to N.  Spreading expiry by ±[ttl_jitter] per key (derived
    from the key's hash, so it is deterministic and reproducible across
    runs) lets co-issued entries drift apart.  Only the [expires_at]/
    [stale_until] instant moves; the freshness window and [stale_grace]
    duration are unchanged.

    Measured on a 13-keeper runtime: ~39 per-keeper cache entries
    ([kta:] / [operator:keeper-runtime-trust] / [kas:keeper-*-agent]) for
    the 13 keepers expired in the same millisecond under a fixed 15s
    [realtime_cache_ttl_s], driving hit_ratio to ~48% with recurring
    recompute spikes every TTL. *)
let ttl_jitter = 0.10

let jittered_ttl ~key ttl =
  let h = Hashtbl.hash key in
  (* low 24 bits of the key hash → [0, 1) *)
  let frac = float_of_int (h land 0xFFFFFF) *. (1.0 /. 16_777_216.0) in
  ttl *. (1.0 +. ((frac *. 2.0) -. 1.0) *. ttl_jitter)

(** PR-0.2.A: dashboard cache hit/miss observation labels.  Pure
    instrumentation — never branches on these counters. *)
let cache_metric_label = [("cache", "dashboard")]

(* Local hit/miss counters in addition to Otel_metric_store, because Otel_metric_store has
   no read-back API in this codebase and we want to surface live ratios via
   [stats ()] without forcing operators through an external metrics backend. *)
let cache_hits_total = Atomic.make 0
let cache_misses_total = Atomic.make 0

let inc_cache_hit () =
  Atomic.incr cache_hits_total;
  Otel_metric_store.inc_counter Otel_metric_store.metric_cache_hits_total
    ~labels:cache_metric_label ()

let inc_cache_miss () =
  Atomic.incr cache_misses_total;
  Otel_metric_store.inc_counter Otel_metric_store.metric_cache_misses_total
    ~labels:cache_metric_label ()

(** Eio path: per-key locking with stampede protection + stale-while-revalidate.

    Three cases on cache lookup:
    1. Fresh ([now < expires_at]) — return immediately.
    2. Stale ([expires_at <= now < stale_until]) — return stale value, kick off
       background recompute if not already running.
    3. Expired ([now >= stale_until]) or absent — block on compute.

    When no stale data is available (case 3 or [Computing { stale = None }]),
    waiters use bounded poll-retry instead of [Condition.await] to avoid
    the cancellation-immune deadlock.  If a [Computing] slot is stuck beyond
    [max_wait_sec ()], waiters evict it and recompute — but the primary
    cleanup path is [release_on_cancel] inside the compute fiber's
    [Eio.Cancel.Cancelled] handler, which releases the slot the moment
    the caller's switch is cancelled.  The watchdog is a floor protection
    that emits [masc_cache_stuck_evictions_total] when it fires.

    Waiter budget is reset when the watched [Computing] slot is replaced
    (detected via [cond] physical identity change), preventing cascading
    eviction of fresh slots. *)
let get_or_compute_eio ?wait_timeout_sec key ~ttl compute =
  let stale_grace = ttl *. stale_factor in
  let rec try_get ~waited ~watching_token =
    let action = atomic_update table (fun map ->
      let map = maybe_evict map in
      match SMap.find_opt key map with
      | Some (Ready entry) when entry.expires_at > now () ->
        (`Hit entry, map)
      | Some (Ready entry) when entry.stale_until > now () ->
        let token = next_token () in
        (`Stale (entry, token), SMap.add key (Computing { token; started_at = now (); stale = Some entry }) map)
      | Some (Computing { stale = Some stale_value; _ }) ->
        (`Hit stale_value, map)
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
        let watchdog_ceiling = max_wait_sec () in
        if timed_out_waiter then
          (`Timed_out, map)
        else if elapsed > watchdog_ceiling || waited > watchdog_ceiling then begin
          Log.Dashboard.warn "cache: evicting stale Computing slot for %s (%.1fs elapsed)" key elapsed;
          (`Retry_stuck (elapsed, watchdog_ceiling), SMap.remove key map)
        end else
          (`Wait token, map)
      | Some (Ready entry) ->
        let token = next_token () in
        (`Compute token, SMap.add key (Computing { token; started_at = now (); stale = Some entry }) map)
      | None ->
        let token = next_token () in
        (`Compute token, SMap.add key (Computing { token; started_at = now (); stale = None }) map)
    ) in
    match action with
    | `Hit entry ->
      (* PR-0.2.A: cache hit observation (no logic change). *)
      inc_cache_hit ();
      entry
    | `Timed_out -> raise (Compute_timeout (key, true))
    | `Wait token ->
      (* Per-fiber ±20% jitter on the poll interval. Concurrent waiters
         parked on the same in-flight cache key (e.g. several keepers
         requesting an expensive execution-surface entry at once) would
         otherwise wake on the identical 0.25s boundary and re-poll in
         lockstep — a poll burst independent of the TTL-expiry stampede
         that [jittered_ttl] already disperses. Spreading wakeups keeps
         the average interval at [wait_poll_interval_sec] while breaking
         the synchronization. [Random]'s default state is OCaml-5
         domain-local and auto-seeded; poll timing is a runtime concern,
         not a deterministic output, so non-determinism is acceptable
         here (unlike the deterministic [jittered_ttl]). *)
      Time_compat.sleep (wait_poll_interval_sec *. (0.8 +. Random.float 0.4));
      try_get ~waited:(waited +. wait_poll_interval_sec) ~watching_token:(Some token)
    | `Stale (stale_entry, token) ->
      (* PR-0.2.A: stale-served-from-cache counts as a hit (caller gets
         data without blocking on compute; bg recompute is incidental). *)
      inc_cache_hit ();
      let do_bg_compute () =
        match compute () with
        | value ->
          let ts = now () in
          let new_entry = {
            value;
            raw = Atomic.make None;
            expires_at = ts +. jittered_ttl ~key ttl;
            stale_until = ts +. jittered_ttl ~key ttl +. stale_grace;
          } in
          atomic_update table (fun map ->
            match SMap.find_opt key map with
            | Some (Computing { token = c; _ }) when c = token ->
              ((), SMap.add key (Ready new_entry) map)
            | _ ->
              Log.Dashboard.info "cache: bg-revalidate discarded for %s (slot replaced)" key;
              ((), map)
          )
        | exception exn ->
          (match exn with
           | Compute_timeout _ -> ()
           | _ when Cancel_safe.is_internal_race_cancel exn ->
               Log.Dashboard.debug "cache bg-revalidate race-cancel for %s, scheduling early retry" key
           | _ -> Log.Dashboard.warn "cache bg-revalidate failed (%s): %s" key (Printexc.to_string exn));
          atomic_update table (fun map ->
            match SMap.find_opt key map with
            | Some (Computing { token = c; _ }) when c = token ->
              let ts = now () in
              let backoff_grace = stale_grace *. bg_revalidate_backoff_factor in
              (* After race-cancel, set expires_at = ts so the next lookup
                 immediately triggers recompute instead of returning stale. *)
              let expires_at =
                if Cancel_safe.is_internal_race_cancel exn then ts else ts +. backoff_grace
              in
              let refreshed = {
                stale_entry with
                expires_at;
                stale_until = ts +. backoff_grace;
              } in
              ((), SMap.add key (Ready refreshed) map)
            | _ -> ((), map)
          )
      and restore_stale_ready () =
        atomic_update table (fun map ->
          match SMap.find_opt key map with
          | Some (Computing { token = c; _ }) when c = token ->
              let ts = now () in
              let backoff_grace = stale_grace *. bg_revalidate_backoff_factor in
              let restored = {
                stale_entry with
                expires_at = ts;
                stale_until = ts +. backoff_grace;
              } in
              ((), SMap.add key (Ready restored) map)
          | _ -> ((), map)
        )
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           (try
              Eio.Fiber.fork ~sw (fun () ->
                try do_bg_compute ()
                with
                | Eio.Cancel.Cancelled _ as e ->
                    restore_stale_ready ();
                    raise e)
            with
            | Invalid_argument _ ->
                restore_stale_ready ()
            | Eio.Cancel.Cancelled _ -> ())
       | None ->
           Log.Dashboard.warn "cache: no switch for background revalidation, computing inline";
           do_bg_compute ());
      stale_entry
    | `Compute token ->
      (* PR-0.2.A: cache miss observation (this fiber must compute). *)
      inc_cache_miss ();
      let result_ref = ref None in
      (* release_on_cancel: when the caller's switch is cancelled (HTTP
         client disconnect, [Eio.Time.with_timeout] tripping the caller
         budget), tear down the [Computing] slot this fiber installed so
         new waiters do not poll an orphan until the watchdog evicts it.

         Scoped to the current fiber's [token]: if a later fiber has
         already replaced the slot, we leave its work alone.  When the
         slot carried a stale fallback, demote it back to [Ready stale]
         so subsequent reads can serve cached data instead of blocking;
         when [stale = None], remove the slot entirely so the next
         lookup observes a cache miss and recomputes. *)
      let release_on_cancel () =
        let ts = now () in
        let backoff_grace = stale_grace *. bg_revalidate_backoff_factor in
        atomic_update table (fun map ->
          match SMap.find_opt key map with
          | Some (Computing { token = c; stale = Some s; _ }) when c = token ->
              let restored = {
                s with
                expires_at = ts;
                stale_until = ts +. backoff_grace;
              } in
              ((), SMap.add key (Ready restored) map)
          | Some (Computing { token = c; stale = None; _ }) when c = token ->
              ((), SMap.remove key map)
          | _ -> ((), map))
      in
      let run_compute () =
        try result_ref := Some (Ok (compute ()))
        with
        | Eio.Cancel.Cancelled _ as e ->
            release_on_cancel ();
            raise e
        | exn -> result_ref := Some (Error exn)
      in
      (* The caller already wraps [compute] in [Eio.Time.with_timeout]
         (see [get_or_compute_with_timeout] below), so running a second
         [Eio.Fiber.first] watchdog here just creates two cancellation
         surfaces racing each other.  Trust the caller's budget and run
         inline.  The poll-loop watchdog [max_wait_sec] above still
         exists as a floor protection if [release_on_cancel] ever
         regresses, and an SLO alert on the stuck-evictions counter
         catches that regression. *)
      run_compute ();
      let ts = now () in
      (match !result_ref with
       | Some (Ok value) ->
           let new_entry = {
             value;
             raw = Atomic.make None;
             expires_at = ts +. jittered_ttl ~key ttl;
             stale_until = ts +. jittered_ttl ~key ttl +. stale_grace;
           } in
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; _ }) when c = token ->
               ((), SMap.add key (Ready new_entry) map)
             | _ ->
               Log.Dashboard.info "cache: compute result discarded for %s (slot replaced)" key;
               ((), map)
           );
           new_entry
       | Some (Error exn) ->
           let fallback_val = ref None in
           if not (Cancel_safe.is_internal_race_cancel exn || is_compute_timeout exn) then
             Log.Dashboard.error "cache revalidation failed: %s" (Printexc.to_string exn);
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; stale = Some stale_value; _ }) when c = token ->
                 let backoff_grace = stale_grace *. bg_revalidate_backoff_factor in
                 let refreshed = {
                   stale_value with
                   expires_at = ts;
                   stale_until = ts +. backoff_grace;
                 } in
                 fallback_val := Some refreshed;
                 ((), SMap.add key (Ready refreshed) map)
             | Some (Computing { token = c; stale = None; _ }) when c = token ->
                 ((), SMap.remove key map)
             | _ -> ((), map)
           );
           (match !fallback_val with
            | Some entry when should_restore_stale_after_failure exn ->
                entry
            | _ -> raise exn)
       | None ->
           let fallback_val = ref None in
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; stale; _ }) when c = token ->
                 (match stale with
                  | Some s ->
                      let cooldown = { s with expires_at = ts +. 5.0; stale_until = ts +. 10.0 } in
                      fallback_val := Some cooldown;
                      ((), SMap.add key (Ready cooldown) map)
                  | None ->
                      let err_json =
                        timeout_error_json ~timeout_kind:"compute" key
                          (max_wait_sec ())
                      in
                      let cooldown = { value = err_json; raw = Atomic.make None; expires_at = ts +. 5.0; stale_until = ts +. 5.0 } in
                      fallback_val := Some cooldown;
                      ((), SMap.add key (Ready cooldown) map))
             | _ -> ((), map)
           );
           (match !fallback_val with
            | Some entry -> entry
            | None ->
                let err_json = timeout_error_json ~timeout_kind:"compute" key (max_wait_sec ()) in
                { value = err_json; raw = Atomic.make None; expires_at = ts +. 5.0; stale_until = ts +. 5.0 }))
    | `Retry_stuck (elapsed, _ceiling) ->
      (* Pair the watchdog with an SLO-actionable signal: if this counter
         climbs sustainedly, [release_on_cancel] is not firing and the
         structural fix has regressed.  Telemetry-as-fix is forbidden by
         the workaround rejection bar; this is telemetry-on-fix-failure. *)
      Otel_metric_store.inc_counter Otel_metric_store.metric_cache_stuck_evictions_total
        ~labels:cache_metric_label ();
      Otel_metric_store.observe_histogram Otel_metric_store.metric_cache_stuck_elapsed_seconds
        ~labels:cache_metric_label elapsed;
      try_get ~waited ~watching_token
  in
  try_get ~waited:0.0 ~watching_token:None

let get_or_compute_simple key ~ttl compute =
  let ts = now () in
  let stale_grace = ttl *. stale_factor in
  match atomic_update table (fun map ->
    let map = maybe_evict map in
    match SMap.find_opt key map with
    | Some (Ready entry) when entry.stale_until > ts ->
      (`Hit entry, map)
    | _ ->
      let token = next_token () in
      (`Compute token, SMap.add key (Computing { token; started_at = ts; stale = None }) map)
  ) with
  | `Hit entry ->
    (* PR-0.2.A: cache hit observation. *)
    inc_cache_hit ();
    entry
  | `Compute token ->
    (* PR-0.2.A: cache miss observation. *)
    inc_cache_miss ();
    (match compute () with
     | value ->
       let ts_after = now () in
       let entry = {
         value;
         raw = Atomic.make None;
         expires_at = ts_after +. jittered_ttl ~key ttl;
         stale_until = ts_after +. jittered_ttl ~key ttl +. stale_grace;
       } in
       atomic_update table (fun map ->
         match SMap.find_opt key map with
         | Some (Computing { token = c; _ }) when c = token ->
           ((), SMap.add key (Ready entry) map)
         | _ -> ((), map)
       );
       entry
     | exception exn ->
       atomic_update table (fun map ->
         match SMap.find_opt key map with
         | Some (Computing { token = c; _ }) when c = token -> ((), SMap.remove key map)
         | _ -> ((), map)
       );
       raise exn)

let get_or_compute_entry key ~ttl compute =
  let entry =
    if Eio_guard.is_ready () then get_or_compute_eio key ~ttl compute
    else get_or_compute_simple key ~ttl compute
  in
  clear_timeout_circuit key;
  entry

let peek_payload key =
  let ts = now () in
  let map = Atomic.get table in
  match SMap.find_opt key map with
  | Some (Ready entry) when entry.stale_until > ts -> Some (payload_of_entry entry)
  | Some (Computing { stale = Some stale_entry; _ }) -> Some (payload_of_entry stale_entry)
  | _ -> None

let peek key =
  match peek_payload key with
  | Some payload -> Some payload.json
  | None -> None

(* RFC-0372 Phase 5 — a bounded compute is still not a yielding compute.

   Phases 1-4 bounded what one dashboard read returns, how many stores it
   merges, and how long it may run. None of that changes *where* it runs.
   Every HTTP connection is a fiber forked onto one domain
   ([server_bootstrap_http.ml]), and Eio fibers switch only at await points.
   [List.sort] and Yojson decoding contain none, so the domain stops for the
   whole pure-compute stretch between two file reads: sibling fibers, including
   [/health], do not run.

   Measured against the live server on 2026-08-12, one telemetry read on an
   otherwise idle process: [/health] median 10-12ms -> 458ms, peak 5137ms,
   back to 14ms the instant the read returned. The control pushed 700x more
   bytes through the same client from a different server and left [/health] at
   17ms median / 48ms peak, so the stall is the server's, not the harness's.
   The per-probe timeline degrades across the entire window rather than in
   periodic spikes, which is the signature of non-yielding compute rather than
   GC pauses.

   [submit_or_inline] moves the work to a worker domain and turns the caller's
   wait into an await point, so sibling fibers run. It is also the only
   sanctioned offload here: [Eio_guard.run_in_systhread] leaves the work with
   no Eio effect handler, which poisons the shared [dir_mu] and takes keeper
   persistence down process-wide (see the note in
   [server_routes_http_routes_provider_runs.ml], which already offloads its own
   dashboard compute this way). Pool workers run inside [Eio.Switch.run], so
   [Eio.Mutex.use_rw ~protect] resolves normally.

   Safe to offload here because [compute] runs without holding the cache lock
   (see the header note); the pool is the only thing the caller waits on.

   Weight stays at the default 1.0. This compute is CPU-bound and occupying a
   whole worker is the intent; RFC-0204 rejects *reclassifying* existing I/O
   submissions to 1.0, which is a different change. Pool size then bounds how
   many computes run at once, so no separate concurrency gate is added. *)
let offloaded compute () = Executor_pool_ref.submit_or_inline compute

let get_or_compute_payload_with_timeout key ~ttl ~clock ~timeout_sec compute =
  if Option.is_none (peek key) && timeout_circuit_is_open key then
    payload_of_json (timeout_error_json ~timeout_kind:"circuit_open" key timeout_sec)
  else
    let compute = offloaded compute in
    try
      let entry =
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
      in
      clear_timeout_circuit key;
      payload_of_entry entry
    with
    | Compute_timeout (key, waiting) ->
        record_timeout_circuit key;
        payload_of_json (timeout_error_json ~waiting key timeout_sec)

let get_or_compute_with_timeout key ~ttl ~clock ~timeout_sec compute =
  (get_or_compute_payload_with_timeout key ~ttl ~clock ~timeout_sec compute).json

(* RFC-0372 Phase 3 — make the timeout the default rather than the opt-in.

   [get_or_compute_with_timeout] has existed for a while, but it requires an
   Eio clock at the call site, so most callers reach for the plain
   [get_or_compute]: at the time of writing 9 call sites take the timeout and
   37 do not. Those 37 compute without any ceiling, which is how one dashboard
   read can hold a domain indefinitely. Converting them one by one is the
   N-of-M patch CLAUDE.md rejects; the ceiling belongs in the default.

   The clock is registered once at boot ([set_default_clock] from main_eio),
   after which every [get_or_compute] runs under a timeout without changing a
   single call site. Before registration — unit tests, non-Eio contexts — the
   original unbounded path still runs, so nothing that never had a clock
   suddenly needs one.

   Individual call sites that need a tighter ceiling keep calling
   [get_or_compute_with_timeout] explicitly; this only removes "no ceiling at
   all" as a reachable state in production. *)
let default_clock : float Eio.Time.clock_ty Eio.Resource.t option Atomic.t =
  Atomic.make None

let set_default_clock clock =
  Atomic.set default_clock
    (Some (clock :> float Eio.Time.clock_ty Eio.Resource.t))

(* Deliberately generous: this is a backstop against unbounded compute, not a
   latency target. The measured worst case for the widest dashboard read was
   ~12s before RFC-0372 Phase 1/2; surfaces that want a tighter bound pass
   their own [timeout_sec]. *)
let default_compute_timeout_sec = 30.0

let get_or_compute_unbounded_payload key ~ttl compute =
  let entry = get_or_compute_entry key ~ttl compute in
  payload_of_entry entry


let get_or_compute_payload key ~ttl compute =
  match Atomic.get default_clock with
  | Some clock ->
    get_or_compute_payload_with_timeout key ~ttl ~clock
      ~timeout_sec:default_compute_timeout_sec compute
  | None -> get_or_compute_unbounded_payload key ~ttl compute

let get_or_compute key ~ttl compute =
  (get_or_compute_payload key ~ttl compute).json
;;

let seed_stale_if_missing key ~stale_for value =
  let ts = now () in
  atomic_update table (fun map ->
      match SMap.find_opt key map with
      | Some _ -> ((), map)
      | None ->
          ((), SMap.add key
            (Ready { value; raw = Atomic.make None; expires_at = ts; stale_until = ts +. stale_for })
            map));
  clear_timeout_circuit key

let invalidate key =
  atomic_update table (fun map -> ((), SMap.remove key map));
  clear_timeout_circuit key

let invalidate_prefix prefix =
  atomic_update table (fun map ->
    ((), SMap.filter (fun k _ -> not (String.starts_with ~prefix k)) map));
  clear_timeout_circuit_prefix prefix

let invalidate_all () =
  Atomic.set table SMap.empty;
  clear_timeout_circuit_all ()

(* Slot kind string used in [stats ()] entry list and tests.  Kept as a
   total function rather than a string buried in [stats ()] so callers can
   pattern-match it (e.g. dashboard UI filters by kind). *)
type slot_kind = Fresh | Stale | Expired | Computing_slot

let slot_kind_to_string = function
  | Fresh -> "fresh"
  | Stale -> "stale"
  | Expired -> "expired"
  | Computing_slot -> "computing"
;;

let slot_kind ~now_ts = function
  | Ready e ->
    if now_ts <= e.expires_at then Fresh
    else if now_ts <= e.stale_until then Stale
    else Expired
  | Computing _ -> Computing_slot
;;

let max_entries_in_stats = 50

let stats () =
  let map = Atomic.get table in
  let now_ts = Time_compat.now () in
  let ready_fresh = ref 0 in
  let ready_stale = ref 0 in
  let ready_expired = ref 0 in
  let computing = ref 0 in
  let entries_acc = ref [] in
  SMap.iter (fun k v ->
    let kind = slot_kind ~now_ts v in
    (match kind with
     | Fresh -> incr ready_fresh
     | Stale -> incr ready_stale
     | Expired -> incr ready_expired
     | Computing_slot -> incr computing);
    let entry_json =
      match v with
      | Ready e ->
        `Assoc [
          ("key", `String k);
          ("kind", `String (slot_kind_to_string kind));
          ("ttl_remaining_ms", `Int (int_of_float ((e.expires_at -. now_ts) *. 1000.0)));
          ("stale_remaining_ms",
           `Int (int_of_float ((e.stale_until -. now_ts) *. 1000.0)));
        ]
      | Computing { started_at; stale; _ } ->
        `Assoc [
          ("key", `String k);
          ("kind", `String "computing");
          ("computing_for_ms", `Int (int_of_float ((now_ts -. started_at) *. 1000.0)));
          ("has_stale_fallback", `Bool (Option.is_some stale));
        ]
    in
    entries_acc := entry_json :: !entries_acc
  ) map;
  (* Truncate per-entry list to bound payload size — operators looking for
     specific keys can use the configured telemetry backend for the full surface. *)
  let entries_list =
    let all = List.rev !entries_acc in
    if List.length all <= max_entries_in_stats
    then all
    else (
      (* Keep the [max_entries_in_stats] entries closest to expiry (most
         actionable) — sort by ttl_remaining_ms ascending and take first N. *)
      let key_of = function
        | `Assoc fields ->
          (match List.assoc_opt "ttl_remaining_ms" fields with
           | Some (`Int n) -> n
           | _ ->
             (match List.assoc_opt "computing_for_ms" fields with
              | Some (`Int n) -> -n  (* computing slots first *)
              | _ -> max_int))
        | _ -> max_int
      in
      List.sort (fun a b -> compare (key_of a) (key_of b)) all
      |> List.filteri (fun i _ -> i < max_entries_in_stats))
  in
  let hits = Atomic.get cache_hits_total in
  let misses = Atomic.get cache_misses_total in
  let total = hits + misses in
  let hit_ratio =
    if total = 0 then 0.0 else float_of_int hits /. float_of_int total
  in
  let timeout_circuit_map = Atomic.get timeout_circuit_table in
  let circuit_open_count =
    SMap.fold (fun _ c acc ->
      if c.opened_until > now_ts then acc + 1 else acc
    ) timeout_circuit_map 0
  in
  `Assoc [
    ("entries", `Int (SMap.cardinal map));
    ("fresh", `Int !ready_fresh);
    ("stale", `Int !ready_stale);
    ("expired", `Int !ready_expired);
    ("ready_fresh", `Int !ready_fresh);
    ("ready_stale", `Int !ready_stale);
    ("computing", `Int !computing);
    ("max_entries", `Int max_entries);
    ("hits_total", `Int hits);
    ("misses_total", `Int misses);
    ("hit_ratio", `Float hit_ratio);
    ("timeout_circuit_open", `Int circuit_open_count);
    ("timeout_circuit_tracked", `Int (SMap.cardinal timeout_circuit_map));
    ("entries_truncated_to", `Int max_entries_in_stats);
    ("entry_details", `List entries_list);
  ]
