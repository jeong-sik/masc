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

type payload_origin = Seeded | Computed | Timeout
type payload_preparation = Identity_only | Http_encodings

type cached_payload = {
  json : Yojson.Safe.t;
  raw_json : string;
  etag : string;
  origin : payload_origin;
  encoded : Http_response_payload.prepared option;
}

let etag_hex_chars = 12

let weak_etag_of_string s =
  let hash = Digest.string s |> Digest.to_hex in
  let sub = String.sub hash 0 (min etag_hex_chars (String.length hash)) in
  "W/\"" ^ sub ^ "\""

let payload_prepared_hook : (cached_payload -> unit) option Atomic.t =
  Atomic.make None

let refresh_registered_hook : (unit -> unit) option Atomic.t = Atomic.make None

type refresh_registration = Queued | Registered | Abandoned

let payload_of_json ?(preparation = Identity_only) ~origin json =
  let raw_json = Yojson.Safe.to_string json in
  let etag = weak_etag_of_string raw_json in
  let encoded =
    match preparation with
    | Identity_only -> None
    | Http_encodings -> Some (Http_response_payload.prepare raw_json)
  in
  let payload = { json; raw_json; etag; origin; encoded } in
  Option.iter (fun hook -> hook payload) (Atomic.get payload_prepared_hook);
  payload

let select_http_representation ~accept_encoding payload =
  match payload.encoded with
  | Some prepared -> Http_response_payload.select_prepared ~accept_encoding prepared
  | None -> payload.raw_json, []

(* Internal JSON projections do not consume HTTP bytes. Keep their value
   available while a later payload reader prepares an identity representation.
   Eio.Lazy coalesces forcing across fibers/domains and restarts on cancellation;
   the atomic is only the nonblocking view used by peek_payload and ready hits. *)
type cached_value =
  | Prepared of cached_payload
  | Json_value of {
      json : Yojson.Safe.t;
      origin : payload_origin;
      prepared : cached_payload option Atomic.t;
      identity : cached_payload Eio.Lazy.t;
    }

type cache_preparation = Cache_json | Cache_http of payload_preparation

let cached_value_of_json ~preparation ~origin json =
  match preparation with
  | Cache_http preparation -> Prepared (payload_of_json ~preparation ~origin json)
  | Cache_json ->
      let prepared = Atomic.make None in
      let identity = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
        payload_of_json ~origin json) in
      Json_value { json; origin; prepared; identity }

(* The value a compute publishes, as work of the kind the compute declared. *)
let prepared_work ~preparation work =
  Pool_work.wrap work (fun body ->
    cached_value_of_json ~preparation ~origin:Computed (body ()))

let json_of_cached_value = function
  | Prepared payload -> payload.json
  | Json_value value -> value.json

let peek_cached_payload = function
  | Prepared payload -> Some payload
  | Json_value value -> Atomic.get value.prepared

let rec remember_prepared prepared payload =
  match Atomic.get prepared with
  | Some current -> current
  | None ->
      if Atomic.compare_and_set prepared None (Some payload) then payload
      else remember_prepared prepared payload

let force_cached_payload = function
  | Prepared payload -> payload
  | Json_value value ->
      (match Atomic.get value.prepared with
       | Some payload -> payload
       | None ->
           let payload =
             match Eio_guard.execution_context () with
             | Eio_guard.Non_eio ->
                 (* A raw thread cannot await Eio.Lazy's running promise.
                    Pure preparation may race, but all readers adopt one result. *)
                 payload_of_json ~origin:value.origin value.json
             | Eio_guard.Eio_fiber ->
                 (* Claim the lazy only inside the worker. Claiming it before
                    queueing deadlocks if that worker requests the same value. *)
                 Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
                   match Atomic.get value.prepared with
                   | Some payload -> payload
                   | None -> Eio.Lazy.force value.identity)
           in
           (* No worker-side publication: an interrupted await cannot publish
              late bytes. This atomic step and the return do not yield. *)
           remember_prepared value.prepared payload)

type entry = {
  payload : cached_value;
  expires_at : float;
  stale_until : float;
}

(* RFC-0204 3.4 L4b. A [Computing] slot with no stale value records who runs
   its compute. The pool job that starts it first claims it: the owner's job,
   or a pool job that looked the key up while the owner's job was still
   queued. Without the claim, that job would hold its worker polling for a
   compute queued behind it. Whoever runs the compute publishes it under the
   slot's token and settles [outcome]; the owner returns on [outcome] as soon
   as it is settled, whether or not its own job has reached a worker. An owner
   that gives up first marks an unclaimed compute [Abandoned] and clears the
   slot; a claimed one stays with whoever runs it. *)
type holder =
  | Unclaimed
  | Owner_job
  | Waiting_job
  | Abandoned

type claim_outcome =
  | Published of entry
  | Failed of exn * Printexc.raw_backtrace
  | Released  (** The runner was cancelled or its window closed; the slot is clear. *)

type claim = {
  holder : holder Atomic.t;
  outcome : claim_outcome Eio.Promise.t;
  settle : claim_outcome Eio.Promise.u;
}

let new_claim () =
  let outcome, settle = Eio.Promise.create () in
  { holder = Atomic.make Unclaimed; outcome; settle }

type slot =
  | Ready of entry
  | Computing of {
      token : int;
      started_at : float;
      stale : entry option;
      claim : claim option;
    }

(* The caller's compute window, applied to whoever runs the compute. *)
type compute_window = { within : 'a. (unit -> 'a) -> 'a }

let unbounded_window = { within = (fun f -> f ()) }

let payload_of_entry entry = entry.payload

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

(** Make room before an absent [incoming_key] would exceed [max_entries], or
    shrink an already overfull table. Prefer expired or stale entries, then
    the fresh entry closest to expiry. Active computations stay owned.
    Must be called inside the mutex-guarded section. *)
let maybe_evict ~incoming_key map =
  let size = SMap.cardinal map in
  if size > max_entries || (size = max_entries && not (SMap.mem incoming_key map)) then begin
    let now_ts = Time_compat.now () in
    let victim = ref None in
    let oldest_fresh = ref None in
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
      | Ready entry ->
          (match !oldest_fresh with
           | Some (_, expires_at) when expires_at <= entry.expires_at -> ()
           | Some _ | None -> oldest_fresh := Some (key, entry.expires_at))
      | Computing _ -> ()
    ) map;
    match !victim with
    | Some (key, _) -> SMap.remove key map
    | None ->
      (* Versioned projection keys can all be fresh after a burst of writes.
         Keep the configured entry bound even before their TTL elapses. *)
      (match !oldest_fresh with
       | Some (key, _) -> SMap.remove key map
       | None -> map)
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

(* Whose window closed: the fiber computing the value, or one waiting on it.
   The envelope's kind is read from this, so it is never inferred later. *)
type compute_timeout_role =
  | Compute_owner
  | Compute_waiter

exception Compute_timeout of { key : string; role : compute_timeout_role }

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

   Every timeout path, in this module and outside it, goes through
   [timeout_envelope_json], and the only sanctioned reader is
   [is_timeout_envelope] beside it. Both read [timeout_error_code], so changing
   the wire value cannot leave a reader behind — a recognizer that lives in
   another module and matches the string itself drifts silently the moment a
   producer changes. The same holds for a producer: one that writes the object
   by hand keeps the old shape when this one changes.

   The envelope still travels in-band, as a value indistinguishable from a
   computed payload until a reader checks; #28400 tracks moving it out of band
   and giving it its own HTTP status. *)
let timeout_error_code = "computation_timeout"

(* Which wait ran out. *)
type timeout_kind =
  | Timeout_owner (* the caller's own compute exceeded its window *)
  | Timeout_waiter (* the caller was waiting on another fiber's compute *)
  | Timeout_compute (* a computing slot yielded no result within [max_wait_sec] *)
  | Timeout_circuit_open (* repeated timeouts for the key: failing fast *)

let timeout_kind_to_string = function
  | Timeout_owner -> "owner"
  | Timeout_waiter -> "waiter"
  | Timeout_compute -> "compute"
  | Timeout_circuit_open -> "circuit_open"

let timeout_envelope_message ~kind ~key ~timeout_sec =
  match kind with
  | Timeout_circuit_open ->
    Printf.sprintf "Dashboard %s is failing fast after repeated cache timeouts" key
  | Timeout_waiter ->
    Printf.sprintf
      "Dashboard %s timed out after %.0fs waiting for an in-flight computation"
      key timeout_sec
  | Timeout_owner | Timeout_compute ->
    Printf.sprintf "Dashboard %s timed out after %.0fs" key timeout_sec

let timeout_envelope_json ~kind ~key ~timeout_sec =
  `Assoc
    [
      ("error", `String timeout_error_code);
      ("message", `String (timeout_envelope_message ~kind ~key ~timeout_sec));
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("timeout_kind", `String (timeout_kind_to_string kind));
      ("timeout_sec", `Float timeout_sec);
      ("key", `String key);
    ]

let is_timeout_envelope = function
  | `Assoc fields ->
    (match List.assoc_opt "error" fields with
     | Some (`String code) -> String.equal code timeout_error_code
     | _ -> false)
  | _ -> false

(* [#28400] Teach the shared HTTP responder layer to recognize this module's
   timeout envelope, so every route that hands a cached get_or_compute value
   straight to [Http_server_eio.Response.json_value] answers 504 + the
   envelope instead of echoing it as HTTP 200 data. Registered at library
   init (this library links before any server route that serves these
   payloads); the responder keeps the no-recognizer no-op path for builds
   that do not link the dashboard producer. *)
let () =
  Http_server_eio.Response.register_timeout_envelope_recognizer
    is_timeout_envelope

let timeout_kind_of_role = function
  | Compute_owner -> Timeout_owner
  | Compute_waiter -> Timeout_waiter

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
    eviction of fresh slots.

    A pool job that would wait on a compute whose owner's job has not started
    claims that compute and runs its own instead of holding its worker idle;
    the owner's job then returns without computing (RFC-0204 3.4 L4b). *)
let get_or_compute_eio ?wait_timeout_sec ?(window = unbounded_window) key ~ttl produce =
  let stale_grace = ttl *. stale_factor in
  let started = now () in
  (* A runner that was cancelled or whose window closed gave up on the
     compute; the compute itself did not fail. *)
  let rec gave_up = function
    | Eio.Cancel.Cancelled _ | Compute_timeout _ -> true
    | Eio.Exn.Multiple exns -> List.exists (fun (exn, _) -> gave_up exn) exns
    | _ -> false
  in
  (* A pool job of the work's kind unless the caller is already inside one. *)
  let compute () =
    window.within (fun () -> Pool_work.submit produce)
  in
  let clear_claimed ~token =
    atomic_update table (fun map ->
      match SMap.find_opt key map with
      | Some (Computing { token = c; _ }) when c = token -> ((), SMap.remove key map)
      | Some (Ready _) | None | Some (Computing _) -> ((), map))
  in
  (* Run a claimed compute, publish it under [token] and settle the claim. A
     claim exists only without a stale value, so failure clears the slot and
     later lookups recompute, as after any owner's failure. *)
  let run_claimed ~token claim run =
    match run () with
    | payload ->
      let ts = now () in
      let entry = {
        payload;
        expires_at = ts +. jittered_ttl ~key ttl;
        stale_until = ts +. jittered_ttl ~key ttl +. stale_grace;
      } in
      atomic_update table (fun map ->
        match SMap.find_opt key map with
        | Some (Computing { token = c; _ }) when c = token ->
          ((), SMap.add key (Ready entry) map)
        | Some (Ready _) | None | Some (Computing _) -> ((), map));
      Eio.Promise.resolve claim.settle (Published entry);
      entry
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      clear_claimed ~token;
      Eio.Promise.resolve claim.settle
        (if gave_up exn then Released else Failed (exn, backtrace));
      Printexc.raise_with_backtrace exn backtrace
  in
  (* The owner of a claimable slot. Its job runs the compute only if it claims
     first. The owner returns on the settled outcome even while its job is
     still queued, which cancels that job before it starts. [`Retry]: whoever
     claimed gave up and cleared the slot, so the owner looks the key up
     again instead of failing for another request's cancellation. *)
  let own_claimed ~token claim =
    let job =
      Pool_work.wrap produce (fun body ->
        if Atomic.compare_and_set claim.holder Unclaimed Owner_job then
          match run_claimed ~token claim body with
          | _entry -> ()
          | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
          | exception _ -> ()  (* settled as [Failed]; the owner raises it below *))
    in
    match
      window.within (fun () ->
        Eio.Fiber.first
          (fun () ->
            Pool_work.submit job;
            Eio.Promise.await claim.outcome)
          (fun () -> Eio.Promise.await claim.outcome))
    with
    | Published entry -> `Entry entry
    | Failed (exn, backtrace) ->
      if not (Cancel_safe.is_internal_race_cancel exn) then
        Log.Dashboard.error "cache revalidation failed: %s" (Printexc.to_string exn);
      Printexc.raise_with_backtrace exn backtrace
    | Released -> `Retry
    | exception exn ->
      (* The owner gave up: cancelled, or its window closed. An unclaimed
         compute is abandoned and its slot cleared. A claimed one is left to
         whoever runs it, which publishes or clears; the owner's own job is
         cancelled with the owner and clears as it exits. *)
      let backtrace = Printexc.get_raw_backtrace () in
      (match exn, Eio.Promise.peek claim.outcome with
       | Compute_timeout _, Some (Published entry) ->
         (* The window closed in the round the claim was published: the
            value is ready, so it is the answer, not a timeout. *)
         `Entry entry
       | _, (None | Some (Published _ | Failed _ | Released)) ->
         if Atomic.compare_and_set claim.holder Unclaimed Abandoned then
           clear_claimed ~token;
         Printexc.raise_with_backtrace exn backtrace)
  in
  let rec try_get ~waited ~watching_token =
    let action = atomic_update table (fun map ->
      let map = maybe_evict ~incoming_key:key map in
      match SMap.find_opt key map with
      | Some (Ready entry) when entry.expires_at > now () ->
        (`Hit entry, map)
      | Some (Ready entry) when entry.stale_until > now () ->
        let token = next_token () in
        (`Stale (entry, token), SMap.add key (Computing { token; started_at = now (); stale = Some entry; claim = None }) map)
      | Some (Computing { stale = Some stale_value; _ }) ->
        (`Hit stale_value, map)
      | Some (Computing { token; started_at; stale = None; claim }) ->
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
          (`Wait (token, claim), map)
      | Some (Ready entry) ->
        let token = next_token () in
        (`Compute (token, None), SMap.add key (Computing { token; started_at = now (); stale = Some entry; claim = None }) map)
      | None ->
        let token = next_token () in
        let claim =
          match Eio_guard.execution_context () with
          | Eio_guard.Eio_fiber -> Some (new_claim ())
          | Eio_guard.Non_eio -> None
        in
        (`Compute (token, claim), SMap.add key (Computing { token; started_at = now (); stale = None; claim }) map)
    ) in
    match action with
    | `Hit entry ->
      (* PR-0.2.A: cache hit observation (no logic change). *)
      inc_cache_hit ();
      entry
    | `Timed_out -> raise (Compute_timeout { key; role = Compute_waiter })
    (* The guard claims: only the job whose CAS succeeds computes. *)
    | `Wait (token, Some claim)
      when Executor_pool_ref.in_worker_context ()
           && Atomic.compare_and_set claim.holder Unclaimed Waiting_job ->
      inc_cache_miss ();
      run_claimed ~token claim compute
    | `Wait (token, (Some _ | None)) ->
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
        | payload ->
          let ts = now () in
          let new_entry = {
            payload;
            expires_at = ts +. jittered_ttl ~key ttl;
            stale_until = ts +. jittered_ttl ~key ttl +. stale_grace;
          } in
          atomic_update table (fun map ->
            match SMap.find_opt key map with
            | Some (Computing { token = c; _ }) when c = token ->
              ((), SMap.add key (Ready new_entry) map)
            | Some (Ready _) | None | Some (Computing _) -> Log.Dashboard.info "cache: bg-revalidate discarded for %s (slot replaced)" key;
              ((), map)
          )
        (* [do_bg_compute] runs inside [Eio.Fiber.fork ~sw] on the process
           root switch. Eio's [fork] hands anything escaping the body to
           [Switch.fail sw], which cancels that switch, so propagating a
           cancellation from here would take the server's root switch down
           over a background cache refresh. The handler below is the fiber's
           last act: a pure [Atomic] update returning the slot to [Ready],
           with [is_internal_race_cancel] giving the loser of an inner
           [Fiber.first] an immediate retry instead of a backoff. Nothing
           runs after it, so absorbing the cancellation ends the fiber
           rather than letting it work on past its own cancellation. *)
        | exception exn -> (* cancel-guard-ok: fork body on the root switch; the handler is the fiber's last act and raising here fails that switch *)
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
            | Some (Ready _) | None | Some (Computing _) -> ((), map)
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
          | Some (Ready _) | None | Some (Computing _) -> ((), map)
        )
      in
      (* Snapshot refreshes can read this cache from an executor worker. Eio
         switches belong to one domain: forking there with the server's root
         switch raises before the refresh starts. Only register the fork on
         the root owner; [compute] still submits its work to the executor.
         The root lifetime also keeps this shared refresh outside a reader's
         turn switch. *)
      let registration = Atomic.make Queued in
      let abandon_registration () =
        if Atomic.compare_and_set registration Queued Abandoned then
          restore_stale_ready ()
      in
      let register_refresh () =
        match SMap.find_opt key (Atomic.get table) with
        | Some (Computing { token = current; _ })
          when current = token
            && Atomic.compare_and_set registration Queued Registered ->
          (* Once the root claims registration, it owns cleanup even if the
             reader is cancelled before the dispatch acknowledgement arrives.
             Resetting its slot from that reader would start a second refresh
             while the first one is still alive. *)
          (try
             (match Eio_context.get_root_switch_opt () with
              | Some sw ->
                (* The reader returns the stale value without waiting, so no
                   request waits on this refresh. The fork inherits the
                   reader's lane, and as a read it could hold the 1-2 read
                   domains for its whole compute budget (RFC-0204 3.4). The
                   inline path below stays a read: there the reader waits. *)
                Eio.Fiber.fork ~sw (fun () ->
                  Pool_lane.with_background @@ fun () ->
                  try do_bg_compute () with
                  | Eio.Cancel.Cancelled _ as e ->
                    restore_stale_ready ();
                    raise e);
                Option.iter (fun hook -> hook ()) (Atomic.get refresh_registered_hook)
              | None ->
                Log.Dashboard.warn "cache: no switch for background revalidation, computing inline";
                do_bg_compute ())
           with
           | Invalid_argument _ -> restore_stale_ready ()
           | Eio.Cancel.Cancelled _ as e ->
             restore_stale_ready ();
             raise e)
        | Some (Ready _) | None | Some (Computing _) -> ()
      in
      (try Eio_context.run_on_owner_domain register_refresh with
       | Invalid_argument _ -> abandon_registration ()
       | Eio.Cancel.Cancelled _ as e ->
         abandon_registration ();
         raise e);
      stale_entry
    | `Compute (token, Some claim) ->
      (* PR-0.2.A: cache miss observation (this fiber must compute). *)
      inc_cache_miss ();
      (match own_claimed ~token claim with
       | `Entry entry -> entry
       | `Retry ->
         (* The window is the caller's; the wait budget keeps counting too. *)
         try_get ~waited:(now () -. started) ~watching_token:None)
    | `Compute (token, None) ->
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
          | Some (Ready _) | None | Some (Computing _) -> ((), map))
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
       | Some (Ok payload) ->
           let new_entry = {
             payload;
             expires_at = ts +. jittered_ttl ~key ttl;
             stale_until = ts +. jittered_ttl ~key ttl +. stale_grace;
           } in
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; _ }) when c = token ->
               ((), SMap.add key (Ready new_entry) map)
             | Some (Ready _) | None | Some (Computing _) -> Log.Dashboard.info "cache: compute result discarded for %s (slot replaced)" key;
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
             | Some (Ready _) | None | Some (Computing _) -> ((), map)
           );
           (match !fallback_val with
            | Some entry when should_restore_stale_after_failure exn ->
                entry
            | _ -> raise exn)
       | None ->
           let fallback_val = ref None in
           let fallback_payload = Prepared (payload_of_json ~origin:Timeout
             (timeout_envelope_json
                ~kind:Timeout_compute ~key ~timeout_sec:(max_wait_sec ()))) in
           atomic_update table (fun map ->
             match SMap.find_opt key map with
             | Some (Computing { token = c; stale; _ }) when c = token ->
                 (match stale with
                  | Some s ->
                      let cooldown = { s with expires_at = ts +. 5.0; stale_until = ts +. 10.0 } in
                      fallback_val := Some cooldown;
                      ((), SMap.add key (Ready cooldown) map)
                  | None ->
                      let cooldown = { payload = fallback_payload; expires_at = ts +. 5.0; stale_until = ts +. 5.0 } in
                      fallback_val := Some cooldown;
                      ((), SMap.add key (Ready cooldown) map))
             | Some (Ready _) | None | Some (Computing _) -> ((), map)
           );
           (match !fallback_val with
            | Some entry -> entry
            | None ->
                { payload = fallback_payload; expires_at = ts +. 5.0; stale_until = ts +. 5.0 }))
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
    let map = maybe_evict ~incoming_key:key map in
    match SMap.find_opt key map with
    | Some (Ready entry) when entry.stale_until > ts ->
      (`Hit entry, map)
    | Some (Computing _) | None | Some (Ready _) -> let token = next_token () in
      (`Compute token, SMap.add key (Computing { token; started_at = ts; stale = None; claim = None }) map)
  ) with
  | `Hit entry ->
    (* PR-0.2.A: cache hit observation. *)
    inc_cache_hit ();
    entry
  | `Compute token ->
    (* PR-0.2.A: cache miss observation. *)
    inc_cache_miss ();
    (match compute () with
     | payload ->
       let ts_after = now () in
       let entry = {
         payload;
         expires_at = ts_after +. jittered_ttl ~key ttl;
         stale_until = ts_after +. jittered_ttl ~key ttl +. stale_grace;
       } in
       atomic_update table (fun map ->
         match SMap.find_opt key map with
         | Some (Computing { token = c; _ }) when c = token ->
           ((), SMap.add key (Ready entry) map)
         | Some (Ready _) | None | Some (Computing _) -> ((), map)
       );
       entry
     | exception exn ->
       atomic_update table (fun map ->
         match SMap.find_opt key map with
         | Some (Computing { token = c; _ }) when c = token -> ((), SMap.remove key map)
         | Some (Ready _) | None | Some (Computing _) -> ((), map)
       );
       raise exn)

let get_or_compute_entry key ~ttl produce =
  let entry =
    if Eio_guard.is_ready () then get_or_compute_eio key ~ttl produce
    else
      get_or_compute_simple key ~ttl (fun () -> Pool_work.submit produce)
  in
  clear_timeout_circuit key;
  entry

let peek_entry key =
  let ts = now () in
  let map = Atomic.get table in
  match SMap.find_opt key map with
  | Some (Ready entry) when entry.stale_until > ts -> Some entry
  | Some (Computing { stale = Some stale_entry; _ }) -> Some stale_entry
  | Some (Computing { stale = None;_}) | None | Some (Ready _) -> None

let peek_payload key =
  Option.bind (peek_entry key) (fun entry -> peek_cached_payload entry.payload)

let peek key =
  Option.map (fun entry -> json_of_cached_value entry.payload) (peek_entry key)

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
   no Eio effect handler, which poisons the first process-shared mutex the
   work takes through [use_rw], such as the one
   [Keeper_types_support.keeper_execution_receipt_store] takes, and takes
   keeper persistence down process-wide (see the note in
   [server_routes_http_routes_provider_runs.ml], which already offloads its own
   dashboard compute this way). Pool workers run inside [Eio.Switch.run], so
   [Eio.Mutex.use_rw ~protect] resolves normally.

   Safe to offload here because [compute] runs without holding the cache lock
   (see the header note); the pool is the only thing the caller waits on.

   The weight is the one the caller declared with its {!Pool_work.t}; the
   cache has none of its own (RFC-0474 L4b). Pool size then bounds how many
   computes run at once, so no separate concurrency gate is added. *)
let offloaded_value produce () = Pool_work.submit produce

(* One compute under the caller's window. A compute that finished as the
   window closed is the answer: [Eio.Time.with_timeout] kept whichever arm
   finished first and would report a payload it already had as a timeout --
   and this timeout is not a one-off, it opens the key's circuit, so the
   next reads answer "circuit_open" without computing at all. *)
let compute_under_timeout ~clock ~timeout_sec ~key f =
  match
    Watched_work.run
      ~watcher:(fun () ->
        Eio.Time.sleep clock timeout_sec;
        Error `Timeout)
      (fun () -> Ok (f ()))
  with
  | Ok value -> value
  | Error `Timeout ->
    Log.Dashboard.warn "cache compute timeout: %s (%.0fs)" key timeout_sec;
    raise (Compute_timeout { key; role = Compute_owner })
;;

let get_or_compute_value_with_timeout ~preparation
    key ~ttl ~clock ~timeout_sec work =
  if Option.is_none (peek key) && timeout_circuit_is_open key then
    Prepared (payload_of_json ~origin:Timeout
      (timeout_envelope_json ~kind:Timeout_circuit_open ~key ~timeout_sec))
  else
    let produce = prepared_work ~preparation work in
    let compute = offloaded_value produce in
    let with_timeout f = compute_under_timeout ~clock ~timeout_sec ~key f in
    (* One window for every attempt of this lookup: a retry after a released
       claim (RFC-0204 3.4 L4b) gets what is left of it, not a fresh one. *)
    let deadline = Eio.Time.now clock +. timeout_sec in
    let within f =
      compute_under_timeout ~clock ~key
        ~timeout_sec:(Float.max 0. (deadline -. Eio.Time.now clock)) f
    in
    try
      let entry =
        if Eio_guard.is_ready () then
          get_or_compute_eio ~wait_timeout_sec:timeout_sec
            ~window:{ within } key ~ttl produce
        else
          get_or_compute_simple key ~ttl (fun () -> with_timeout compute)
      in
      clear_timeout_circuit key;
      payload_of_entry entry
    with
    | Compute_timeout { key; role } ->
        record_timeout_circuit key;
        Prepared (payload_of_json ~origin:Timeout
          (timeout_envelope_json
             ~kind:(timeout_kind_of_role role) ~key ~timeout_sec))

let get_or_compute_payload_with_timeout ?(preparation = Identity_only)
    key ~ttl ~clock ~timeout_sec work =
  let value = get_or_compute_value_with_timeout
    ~preparation:(Cache_http preparation) key ~ttl ~clock ~timeout_sec work in
  match peek_cached_payload value with
  | Some payload -> payload
  | None ->
      (match Eio_guard.execution_context () with
       | Eio_guard.Non_eio -> force_cached_payload value
       | Eio_guard.Eio_fiber ->
           try compute_under_timeout ~clock ~timeout_sec ~key
             (fun () -> force_cached_payload value)
           with Compute_timeout { key; role } ->
             record_timeout_circuit key;
             payload_of_json ~origin:Timeout
               (timeout_envelope_json
                  ~kind:(timeout_kind_of_role role) ~key ~timeout_sec))

let get_or_compute_with_timeout key ~ttl ~clock ~timeout_sec work =
  get_or_compute_value_with_timeout ~preparation:Cache_json
    key ~ttl ~clock ~timeout_sec work
  |> json_of_cached_value

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

let get_or_compute_unbounded_value ~preparation key ~ttl work =
  let entry = get_or_compute_entry key ~ttl (prepared_work ~preparation work) in
  payload_of_entry entry


let get_or_compute_payload ?(preparation = Identity_only) key ~ttl work =
  match Atomic.get default_clock with
  | Some clock ->
    get_or_compute_payload_with_timeout ~preparation key ~ttl ~clock
      ~timeout_sec:default_compute_timeout_sec work
  | None ->
      get_or_compute_unbounded_value ~preparation:(Cache_http preparation) key ~ttl work
      |> force_cached_payload

let get_or_compute key ~ttl work =
  match Atomic.get default_clock with
  | Some clock -> get_or_compute_with_timeout key ~ttl ~clock
      ~timeout_sec:default_compute_timeout_sec work
  | None ->
      get_or_compute_unbounded_value ~preparation:Cache_json key ~ttl work
      |> json_of_cached_value
;;

let seed_stale_if_missing key ~stale_for value =
  if not (SMap.mem key (Atomic.get table)) then begin
    (* Warming seeds are small and must remain available even while all workers
       are busy. Prepare before publication, without queueing behind refreshes. *)
    let payload = Prepared (payload_of_json ~origin:Seeded value) in
    let ts = now () in
    atomic_update table (fun map ->
        match SMap.find_opt key map with
        | Some _ -> ((), map)
        | None ->
            ((), SMap.add key
              (Ready { payload; expires_at = ts; stale_until = ts +. stale_for })
              map))
  end;
  clear_timeout_circuit key

let seed_stale_from_if_missing key ~from ~stale_for =
  match peek_entry from with
  | None -> ()
  | Some source ->
    (* The source's prepared bytes and entity tag travel with it: the seed
       is the same page, so it is neither serialized nor hashed again. *)
    let ts = now () in
    atomic_update table (fun map ->
        match SMap.find_opt key map with
        | Some _ -> ((), map)
        | None ->
            ((), SMap.add key
              (Ready { source with expires_at = ts; stale_until = ts +. stale_for })
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

module For_testing = struct
  let with_default_clock clock f =
    let previous = Atomic.exchange default_clock
      (Some (clock :> float Eio.Time.clock_ty Eio.Resource.t)) in
    Fun.protect ~finally:(fun () -> Atomic.set default_clock previous) f

  let with_refresh_registered_hook hook f =
    let previous = Atomic.exchange refresh_registered_hook (Some hook) in
    Fun.protect
      ~finally:(fun () -> Atomic.set refresh_registered_hook previous)
      f

  let with_payload_prepared_hook hook f =
    let previous = Atomic.exchange payload_prepared_hook (Some hook) in
    Fun.protect
      ~finally:(fun () -> Atomic.set payload_prepared_hook previous)
      f

  let compute_under_timeout = compute_under_timeout
end

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
