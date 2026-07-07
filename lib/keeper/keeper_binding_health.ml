(** Reactive health tracking for runtime providers.

    Tracks per-provider success/failure rates using a rolling time window.
    Providers in cooldown (consecutive failures exceed threshold) are
    temporarily skipped.  Health data feeds into weighted runtime selection
    via {!effective_weight}.

    Design: LiteLLM cooldown + OpenRouter rolling-window hybrid.
    See RFC-OAS-006 Phase 2.

    Thread safety: uses [Stdlib.Mutex] (not Eio.Mutex) for cross-fiber
    safety without Eio dependency in the hot path.  Critical sections are
    small (record append + list scan).

    @since 0.137.0 *)

let window_sec = Keeper_binding_health_config.window_sec
let cooldown_threshold = Keeper_binding_health_config.cooldown_threshold
let cooldown_sec = Keeper_binding_health_config.cooldown_sec
let hard_quota_cooldown_sec = Keeper_binding_health_config.hard_quota_cooldown_sec
let terminal_failure_cooldown_sec =
  Keeper_binding_health_config.terminal_failure_cooldown_sec

let server_error_cooldown_sec =
  Keeper_binding_health_config.server_error_cooldown_sec

let soft_rate_limit_cooldown_sec =
  Keeper_binding_health_config.soft_rate_limit_cooldown_sec

let soft_rate_limit_max_clamp_sec =
  Keeper_binding_health_config.soft_rate_limit_max_clamp_sec

let default_capacity_backpressure_backoff_sec =
  Keeper_binding_health_config.default_capacity_backpressure_backoff_sec

let latency_ring_size = Keeper_binding_health_config.latency_ring_size
let confidence_ring_size = Keeper_binding_health_config.confidence_ring_size
let cost_ring_size = Keeper_binding_health_config.cost_ring_size
let cooldown_config_for = Keeper_binding_health_config.cooldown_config_for


(* ── Types ────────────────────────────────────── *)

(* [Rejected] is the third outcome kind introduced in 0.160.0.  It
   represents "response arrived but the runtime's accept predicate
   rejected it" — behaviorally equivalent to [Failure] (same cooldown
   trigger, same success-rate impact) but visible to the dashboard so
   operators can tell a down provider apart from one whose outputs are
   consistently unusable. *)
(* [Hard_quota] is the fourth outcome kind introduced in 0.161.0.  It
   represents "provider returned a terminal quota-exhaustion error (balance
   0, monthly quota reached, resource exhausted)" — classified via OAS
   [Llm_provider.Retry.is_hard_quota].  Unlike [Failure], a single event
   triggers an immediate long cooldown ([hard_quota_cooldown_sec]); the
   [cooldown_threshold] does not apply because retry on the next runtime
   tick is pointless when the upstream account is out of credit. *)
(* [Terminal_failure] represents structural provider/adapter failures that are
   deterministic for the current runtime state.  A provider CLI
   resumable-session conflict is the motivating case: fallback is correct for
   the current call, but repeatedly attempting the same provider first on every
   later call only adds latency and silently degrades runtime diversity. *)
(* [Server_error] represents upstream HTTP 5xx.  It is usually transient, but
   OAS has already spent its owned retry/backoff by the time this reaches MASC;
   a medium immediate cooldown prevents scheduled keeper cycles from paging
   operators repeatedly on the same unhealthy cloud lane. *)
(* [Soft_rate_limited] represents a transient HTTP 429 — provider is healthy
   but momentarily over its rate budget.  Distinct from [Failure] so a single
   event triggers an immediate (short) cooldown without waiting for the
   [cooldown_threshold] consecutive-failure count.  Distinct from [Hard_quota]
   because the provider is expected to recover within seconds, not hours. *)
type outcome =
  | Success
  | Failure
  | Rejected
  | Hard_quota
  | Terminal_failure
  | Server_error
  | Soft_rate_limited
  | Capacity_backpressure

(* Public mirror of [outcome].  Defined here (rather than beside
   [recent_outcome_count] where it originated) so [build_info_locked] can expose
   the cooldown-arming outcome on [provider_info] without leaking the internal
   [outcome] type.  See [outcome_matches] for the paired exhaustive match that
   guards against the two types drifting. *)
type outcome_kind =
  | Outcome_success
  | Outcome_failure
  | Outcome_rejected
  | Outcome_hard_quota
  | Outcome_terminal_failure
  | Outcome_server_error
  | Outcome_soft_rate_limited
  | Outcome_capacity_backpressure

let outcome_kind_of_outcome = function
  | Success -> Outcome_success
  | Failure -> Outcome_failure
  | Rejected -> Outcome_rejected
  | Hard_quota -> Outcome_hard_quota
  | Terminal_failure -> Outcome_terminal_failure
  | Server_error -> Outcome_server_error
  | Soft_rate_limited -> Outcome_soft_rate_limited
  | Capacity_backpressure -> Outcome_capacity_backpressure

type event = {
  time: float;  (* Unix timestamp *)
  outcome: outcome;
}

type provider_state = {
  mutable events: event list;  (* newest first *)
  mutable consecutive_failures: int;
  mutable cooldown_until: float;  (* 0.0 = not in cooldown *)
  mutable cooldown_cause: outcome option;
  (* The outcome that armed the current cooldown window (set wherever
     [cooldown_until] is advanced, cleared on success/expiry).  [None] when
     not in cooldown, or for a cooldown restored from persistence (the cause is
     not persisted; it is re-armed on the next real failure).  Read by the
     pre-dispatch cooldown gate so a deterministic arming cause escalates
     instead of oscillating.  #23438. *)
  fingerprint_counts: (string, int) Hashtbl.t;
  (* Per-fingerprint cumulative counter (lifetime, no rolling decay).
     Phase 0 observability anchor for "which error keeps recurring".
     Updated under [t.mu]. *)
  mutable last_failure_at: float;  (* 0.0 = none *)
  (* Latency ring buffer for recent successful-call durations (ms).
     Allocated lazily on first sample to avoid an empty array per
     never-tracked provider.  Capacity is bounded by [latency_ring_size]
     at module-load time.  When [latency_ring_size <= 0] the ring stays
     [None] forever and percentile reads return [None]. *)
  mutable latency_ring: float array option;
  mutable latency_count: int;     (* slots filled, capped at array length *)
  mutable latency_cursor: int;    (* next insertion index, wraps mod length *)
  (* Confidence ring buffer for avg log probability per token from LLM
     responses.  Mirrors the latency ring pattern: lazy allocation,
     drop-oldest on overflow, bounded by [confidence_ring_size].
     Values are negative log probs — lower (more negative) = higher
     confidence in the response quality. *)
  mutable confidence_ring: float array option;
  mutable confidence_count: int;
  mutable confidence_cursor: int;
  (* Cost ring buffer for per-request inference cost (USD).  Mirrors the
     latency ring pattern: lazy allocation, drop-oldest, bounded by
     [cost_ring_size].  Values are non-negative USD amounts. *)
  mutable cost_ring: float array option;
  mutable cost_count: int;
  mutable cost_cursor: int;
}

type t = {
  providers: (string, provider_state) Hashtbl.t;
  mu: Stdlib.Mutex.t;
}

type error_kind = Error_kind of string

let error_kind_of_string value = Error_kind value
let error_kind_to_string (Error_kind value) = value

type provider_restore = {
  restore_provider_key : string;
  restore_consecutive_failures : int;
  restore_cooldown_until : float option;
  restore_last_failure_at : float option;
  restore_top_fingerprints : (string * int) list;
  restore_latency_ms : float option;
  restore_confidence : float option;
  restore_cost_usd : float option;
}

(* ── Constructor ──────────────────────────────── *)

let create () : t = {
  providers = Hashtbl.create 8;
  mu = Stdlib.Mutex.create ();
}

(* #9873: Stdlib.Mutex, not Eio.Mutex, per the module doc at line 11.

   The drift (doc said Stdlib, code used Eio) caused 12 test failures
   in test_keeper_unified because [Eio.Mutex.use_rw] depends on the
   [Cancel.Get_context] effect handler, which is only installed
   inside an [Eio_main.run] event loop. Tests calling
   [provider_cooldown_remaining_sec_for_runtime → provider_info]
   outside that loop propagate [Stdlib.Effect.Unhandled].

   Stdlib.Mutex has no effect dependency — a keeper scheduling
   check can run under an Eio fiber OR a bare test, and in either
   case the critical section (record append + list scan) is small
   enough to be pure-blocking without the cooperative-yield
   semantics Eio.Mutex provides.

   Per feedback memory feedback_ocaml5-mutex-selection.md:
   - Same domain Eio.Mutex → EDEADLK risk on reentrant paths
   - Cross-domain Stdlib.Mutex or Eio.Promise
   This module is cross-fiber but single-domain; Stdlib.Mutex is
   the correct pick and matches the documented design. *)
let with_lock t f =
  Stdlib.Mutex.lock t.mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock t.mu)
    (fun () -> f ())

let get_or_create_state t key =
  match Hashtbl.find_opt t.providers key with
  | Some s -> s
  | None ->
    let s = {
      events = [];
      consecutive_failures = 0;
      cooldown_until = 0.0;
      cooldown_cause = None;
      fingerprint_counts = Hashtbl.create 4;
      last_failure_at = 0.0;
      latency_ring = None;
      latency_count = 0;
      latency_cursor = 0;
      confidence_ring = None;
      confidence_count = 0;
      confidence_cursor = 0;
      cost_ring = None;
      cost_count = 0;
      cost_cursor = 0;
    } in
    Hashtbl.replace t.providers key s;
    s

let finite_positive = function
  | Some value when Float.is_finite value && value > 0.0 -> Some value
  | _ -> None

let restore_latency_sample state = function
  | Some lat_ms when latency_ring_size > 0
                     && Float.is_finite lat_ms
                     && lat_ms > 0.0 ->
    let ring = Array.make latency_ring_size 0.0 in
    ring.(0) <- lat_ms;
    state.latency_ring <- Some ring;
    state.latency_count <- 1;
    state.latency_cursor <- (if latency_ring_size = 1 then 0 else 1)
  | _ -> ()

let restore_confidence_sample state = function
  | Some confidence when confidence_ring_size > 0
                         && Float.is_finite confidence ->
    let ring = Array.make confidence_ring_size 0.0 in
    ring.(0) <- confidence;
    state.confidence_ring <- Some ring;
    state.confidence_count <- 1;
    state.confidence_cursor <- (if confidence_ring_size = 1 then 0 else 1)
  | _ -> ()

let restore_cost_sample state = function
  | Some cost_usd when cost_ring_size > 0
                       && Float.is_finite cost_usd
                       && cost_usd >= 0.0 ->
    let ring = Array.make cost_ring_size 0.0 in
    ring.(0) <- cost_usd;
    state.cost_ring <- Some ring;
    state.cost_count <- 1;
    state.cost_cursor <- (if cost_ring_size = 1 then 0 else 1)
  | _ -> ()

let restore_providers t providers =
  with_lock t (fun () ->
    let now = Unix.gettimeofday () in
    List.fold_left
      (fun restored row ->
        let provider_key = String.trim row.restore_provider_key in
        if String.equal provider_key ""
        then restored
        else (
          let state = get_or_create_state t provider_key in
          state.consecutive_failures <- max 0 row.restore_consecutive_failures;
          state.cooldown_until
          <- (match finite_positive row.restore_cooldown_until with
              | Some ts when ts > now -> ts
              | _ -> 0.0);
          (* The arming cause is not persisted; a restored cooldown reports no
             cause until the next real failure re-arms it.  #23438. *)
          state.cooldown_cause <- None;
          state.last_failure_at
          <- (match finite_positive row.restore_last_failure_at with
              | Some ts -> ts
              | None -> 0.0);
          Hashtbl.reset state.fingerprint_counts;
          List.iter
            (fun (fp, count) ->
              let fp = String.trim fp in
              if (not (String.equal fp "")) && count > 0
              then Hashtbl.replace state.fingerprint_counts fp count)
            row.restore_top_fingerprints;
          restore_latency_sample state row.restore_latency_ms;
          restore_confidence_sample state row.restore_confidence;
          restore_cost_sample state row.restore_cost_usd;
          restored + 1))
      0
      providers)

(* Append [latency_ms] to the per-provider ring buffer.  Allocates the
   array lazily on first valid sample so providers that never report
   timing never pay for the slot.  Drops samples that are non-finite or
   non-positive — a successful-call duration of 0 or NaN is a caller bug
   we don't want polluting the percentile. *)
let push_latency state lat_ms =
  if latency_ring_size <= 0 then ()
  else if not (Float.is_finite lat_ms) || lat_ms <= 0.0 then ()
  else begin
    let ring =
      match state.latency_ring with
      | Some r -> r
      | None ->
        let r = Array.make latency_ring_size 0.0 in
        state.latency_ring <- Some r;
        r
    in
    ring.(state.latency_cursor) <- lat_ms;
    state.latency_cursor <- (state.latency_cursor + 1) mod latency_ring_size;
    if state.latency_count < latency_ring_size then
      state.latency_count <- state.latency_count + 1
  end

(* Append [conf] (avg log prob per token) to the per-provider confidence ring.
   Accepts negative values — most LLM log probs are negative.  Non-finite
   values are silently dropped.  Same lazy-allocation pattern as
   [push_latency]. *)
let push_confidence state conf =
  if confidence_ring_size <= 0 then ()
  else if not (Float.is_finite conf) then ()
  else begin
    let ring =
      match state.confidence_ring with
      | Some r -> r
      | None ->
        let r = Array.make confidence_ring_size 0.0 in
        state.confidence_ring <- Some r;
        r
    in
    ring.(state.confidence_cursor) <- conf;
    state.confidence_cursor <- (state.confidence_cursor + 1) mod confidence_ring_size;
    if state.confidence_count < confidence_ring_size then
      state.confidence_count <- state.confidence_count + 1
  end

let push_cost state cost =
  if cost_ring_size <= 0 then ()
  else if not (Float.is_finite cost) || cost < 0.0 then ()
  else begin
    let ring =
      match state.cost_ring with
      | Some r -> r
      | None ->
        let r = Array.make cost_ring_size 0.0 in
        state.cost_ring <- Some r;
        r
    in
    ring.(state.cost_cursor) <- cost;
    state.cost_cursor <- (state.cost_cursor + 1) mod cost_ring_size;
    if state.cost_count < cost_ring_size then
      state.cost_count <- state.cost_count + 1
  end

(* Build a stable fingerprint from caller-provided classification.
   Format: "kind|hash8(reason)" — kind defaults to "unclassified",
   hash suffix is omitted when reason is absent or empty.  Hash is
   MD5-truncated to 8 hex chars: collision-tolerant for an
   observability-only counter. *)
let make_fingerprint ?error_kind ?error_reason () =
  let kind =
    match error_kind with
    | Some k ->
      let trimmed = String.trim (error_kind_to_string k) in
      if trimmed = "" then "unclassified" else trimmed
    | _ -> "unclassified"
  in
  match error_reason with
  | None -> kind
  | Some r ->
    let r = String.trim r in
    if r = "" then kind
    else
      let h = Digest.to_hex (Digest.string r) in
      let h_short =
        if String.length h >= 8 then String.sub h 0 8 else h
      in
      kind ^ "|" ^ h_short

let bump_fingerprint state fp =
  let prev =
    match Hashtbl.find_opt state.fingerprint_counts fp with
    | Some n -> n
    | None -> 0
  in
  Hashtbl.replace state.fingerprint_counts fp (prev + 1)

(* ── Recording ────────────────────────────────── *)

let prune_old_events now events =
  let cutoff = now -. window_sec in
  List.filter (fun e -> e.time >= cutoff) events

let record t ~provider_key ~outcome ?error_kind ?error_reason
    ?retry_after_s ?latency_ms ?confidence ?cost_usd ~now () =
  with_lock t (fun () ->
    let state = get_or_create_state t provider_key in
    let event = { time = now; outcome } in
    state.events <- event :: prune_old_events now state.events;
    let bump_failure_fp () =
      let fp = make_fingerprint ?error_kind ?error_reason () in
      bump_fingerprint state fp;
      state.last_failure_at <- now
    in
    match outcome with
    | Success ->
      state.consecutive_failures <- 0;
      (* Clear cooldown on success — provider recovered *)
      state.cooldown_until <- 0.0;
      state.cooldown_cause <- None;
      (* Append latency sample when caller provided one.  Non-success
         outcomes don't contribute to the percentile — a 200ms timeout
         and a 200ms successful response are not the same signal. *)
      (match latency_ms with
       | Some ms -> push_latency state ms
       | None -> ());
      (match confidence with
       | Some c -> push_confidence state c
       | None -> ());
      (match cost_usd with
       | Some c -> push_cost state c
       | None -> ())
    | Failure | Rejected ->
      (* Rejected responses indicate unusable output (gate reject, empty
         body, schema miss).  Treat identically to Failure for cooldown
         and consecutive-failure tracking — a provider whose responses
         are consistently rejected is as useless as one that never
         responds.  The outcome tag is preserved in [events] so
         [provider_info] can count Rejected separately for dashboards. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let (threshold, cooldown_dur) = cooldown_config_for ~provider_key in
      if state.consecutive_failures >= threshold then begin
        let new_until = now +. cooldown_dur in
        if new_until > state.cooldown_until then begin
          state.cooldown_until <- new_until;
          state.cooldown_cause <- Some outcome;
          Runtime_metrics.on_provider_cooldown
            ~provider:provider_key ~reason:"failure_threshold";
          Otel_metric_store.observe_histogram Keeper_metrics.(to_string ProviderBlockDurationSec)
            ~labels:[("provider", provider_key)] cooldown_dur
        end
      end
    | Soft_rate_limited ->
      (* Transient HTTP 429.  Apply an immediate short cooldown so the
         current runtime cycle skips this provider for the next selection
         tick — without forcing the [cooldown_threshold] count-to-three
         that [Failure] uses.  Honor caller-supplied Retry-After when
         present; clamp positive values to [soft_rate_limit_max_clamp_sec]
         to prevent a misclassified hard quota from silently producing
         a multi-minute blackout.  Negative / zero / absent values fall
         back to [soft_rate_limit_cooldown_sec].  As with the other
         immediate-cooldown paths, never shorten an already-longer
         cooldown (e.g. concurrent hard_quota + soft_rl events). *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let cooldown_dur =
        match retry_after_s with
        | Some s when s > 0.0 -> Float.min s soft_rate_limit_max_clamp_sec
        | _ -> soft_rate_limit_cooldown_sec
      in
      let new_until = now +. cooldown_dur in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        state.cooldown_cause <- Some outcome;
        Runtime_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"soft_rate_limit";
        Otel_metric_store.observe_histogram Keeper_metrics.(to_string ProviderBlockDurationSec)
          ~labels:[("provider", provider_key)] cooldown_dur
      end
    | Capacity_backpressure ->
      (* Capacity exhaustion is transient load, not persistent health
         degradation.  Do NOT increment consecutive_failures.
         Apply cooldown using the upstream retry_after hint when present,
         or a synthetic default otherwise, so the fleet-level backoff
         logic can detect all-provider-cooldown and wait for recovery
         instead of thrashing through every provider every turn. *)
      let cooldown_dur =
        match retry_after_s with
        | Some s when s > 0.0 -> Float.min s soft_rate_limit_max_clamp_sec
        | _ -> default_capacity_backpressure_backoff_sec
      in
      let new_until = now +. cooldown_dur in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        state.cooldown_cause <- Some outcome;
        Runtime_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"capacity_backpressure";
        Otel_metric_store.observe_histogram Keeper_metrics.(to_string ProviderBlockDurationSec)
          ~labels:[("provider", provider_key)] cooldown_dur
      end
    | Hard_quota ->
      (* Hard-quota errors (balance depleted, quota exceeded, resource
         exhausted) don't recover on short-window retries — set a long
         cooldown immediately regardless of [consecutive_failures].  We
         still increment the counter for dashboard continuity.  Preserve
         an already-longer cooldown (e.g. if two hard-quota events fire
         concurrently and the second arrives first in wall time). *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let new_until = now +. hard_quota_cooldown_sec in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        state.cooldown_cause <- Some outcome;
        Runtime_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"hard_quota";
        Otel_metric_store.observe_histogram Keeper_metrics.(to_string ProviderBlockDurationSec)
          ~labels:[("provider", provider_key)] hard_quota_cooldown_sec
      end
    | Terminal_failure ->
      (* Terminal structural errors are not quota exhaustion, but they have the
         same retry shape: the next runtime tick will hit the same provider
         state and fail again.  Cool down immediately to keep fallback from
         becoming a hidden tax on every request.  #10441: the
         [apply_trust_failure_locked] step was removed by #10412 (Phase 1
         revert).  Keep [bump_failure_fp] for fingerprint history but discard
         its return value — there's no trust adjustment to feed it into. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let new_until = now +. terminal_failure_cooldown_sec in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        state.cooldown_cause <- Some outcome;
        Runtime_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"terminal_failure";
        Otel_metric_store.observe_histogram
          Keeper_metrics.(to_string ProviderBlockDurationSec)
          ~labels:[ ("provider", provider_key) ]
          terminal_failure_cooldown_sec
      end
    | Server_error ->
      (* Upstream HTTP 5xx can recover without operator action, so it should not
         use terminal-failure blackout.  It still needs an immediate medium
         cooldown because thresholded generic failures are shorter than many
         keeper autonomous cadences and therefore fail to break repeated pages. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      bump_failure_fp ();
      let new_until = now +. server_error_cooldown_sec in
      if new_until > state.cooldown_until then begin
        state.cooldown_until <- new_until;
        state.cooldown_cause <- Some outcome;
        Runtime_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"server_error";
        Otel_metric_store.observe_histogram
          Keeper_metrics.(to_string ProviderBlockDurationSec)
          ~labels:[ ("provider", provider_key) ]
          server_error_cooldown_sec
      end)

let record_success t ~provider_key ?latency_ms ?confidence ?cost_usd () =
  record t ~provider_key ~outcome:Success ?latency_ms ?confidence ?cost_usd
    ~now:(Unix.gettimeofday ()) ()

let record_failure t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Failure ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

let record_rejected t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Rejected ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

let record_hard_quota t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Hard_quota ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

let record_terminal_failure t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Terminal_failure ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

let record_server_error t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Server_error ?error_kind ?error_reason
    (* NDT-OK: runtime provider-health telemetry boundary; deterministic tests
       can exercise the underlying [record] path with an explicit [~now]. *)
    ~now:(Unix.gettimeofday ()) ()

let record_soft_rate_limited t ~provider_key ?retry_after_s ?error_kind
    ?error_reason () =
  record t ~provider_key ~outcome:Soft_rate_limited ?error_kind ?error_reason
    ?retry_after_s ~now:(Unix.gettimeofday ()) ()

let record_capacity_backpressure t ~provider_key ?retry_after_s ?error_kind
    ?error_reason ~now () =
  record t ~provider_key ~outcome:Capacity_backpressure ?error_kind ?error_reason
    ?retry_after_s ~now ()

(* ── Queries ──────────────────────────────────── *)

(** Success rate in the rolling window.  Returns 1.0 for unknown
    providers (optimistic default — no data means no reason to penalize). *)
let success_rate t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> 1.0
    | Some state ->
      let now = Unix.gettimeofday () in
      let recent = prune_old_events now state.events in
      match recent with
      | [] -> 1.0
      | _ ->
        let successes = List.length
            (List.filter (fun e -> e.outcome = Success) recent) in
        float_of_int successes /. float_of_int (List.length recent))

(** Whether the provider is currently in cooldown.  A cooled-down provider
    should be skipped in runtime selection.

    @return [true] if in cooldown AND cooldown has not expired *)
let is_in_cooldown t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> false
    | Some state ->
      let now = Unix.gettimeofday () in
      if state.cooldown_until > now then true
      else begin
        (* Expired cooldown — clear it *)
        if state.cooldown_until > 0.0 then
          state.cooldown_until <- 0.0;
        state.cooldown_cause <- None;
        false
      end)

(** [is_capacity_constrained t ~provider_key] returns [true] when the
    provider's most recent event is [Capacity_backpressure] and the
    resulting cooldown has not yet expired.  Used for pre-admission
    filtering: skip providers that recently signalled capacity exhaustion
    before spending OAS body budget on a doomed attempt. *)
let is_capacity_constrained t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> false
    | Some state ->
      (* DET-OK: read-only time check, same pattern as is_in_cooldown:546 *)
      let now = Unix.gettimeofday () in
      (* If general cooldown is still active, check if it was capacity-induced *)
      if state.cooldown_until > now
      then (
        match state.events with
        | { outcome = Capacity_backpressure; _ } :: _ -> true
        | _ -> false)
      else false)

let check_circuit_breaker t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> Ok ()
    | Some state ->
      let now = Unix.gettimeofday () in
      if state.cooldown_until > now then
        let remaining = max 0 (int_of_float (Float.ceil (state.cooldown_until -. now))) in
        Error (Printf.sprintf "provider cooldown active; retry in %ds" remaining)
      else begin
        if state.cooldown_until > 0.0 then
          state.cooldown_until <- 0.0;
        state.cooldown_cause <- None;
        Ok ()
      end)

(** Compute effective weight for a provider.

    [effective_weight = config_weight * success_rate]

    Providers in cooldown get weight 0 (skipped).  Unknown providers
    get their full config weight (optimistic). *)
let effective_weight t ~provider_key ~config_weight =
  if is_in_cooldown t ~provider_key then 0
  else
    let rate = success_rate t ~provider_key in
    max 1 (int_of_float (float_of_int config_weight *. rate))

(** Summary for debugging/telemetry. *)
let provider_summary t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> Printf.sprintf "%s: no data" provider_key
    | Some state ->
      let now = Unix.gettimeofday () in
      let recent = prune_old_events now state.events in
      let total = List.length recent in
      let successes = List.length
          (List.filter (fun e -> e.outcome = Success) recent) in
      let in_cd = state.cooldown_until > now in
      Printf.sprintf "%s: %d/%d ok (%.0f%%) consec_fail=%d cooldown=%b"
        provider_key successes total
        (if total > 0 then 100.0 *. float_of_int successes /. float_of_int total else 100.0)
        state.consecutive_failures in_cd)

(** Structured provider snapshot — shared by [provider_info] and [all_providers].
    Built inside the mutex so the snapshot is consistent. *)
type provider_info = {
  provider_key : string;
  success_rate : float;
  consecutive_failures : int;
  in_cooldown : bool;
  cooldown_expires_at : float option;
  cooldown_cause : outcome_kind option;
  events_in_window : int;
  rejected_in_window : int;
  top_fingerprints : (string * int) list;
  last_failure_at : float option;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  latency_samples : int;
  avg_confidence : float option;
  confidence_samples : int;
  avg_cost_usd : float option;
  cost_samples : int;
  health_score : float;
}

(* Compute the [pct]-th percentile (0.0–1.0) of the populated portion of
   the latency ring.  [None] when no samples have been recorded.

   Method: copy the populated slice into a fresh array, sort ascending,
   pick by linear-interpolation between adjacent ranks (NIST H.7 / type
   7 — same convention numpy / pandas use).  The full distribution is
   only needed for monitoring, not for high-frequency strategy reads,
   so the O(n log n) sort on n≤[latency_ring_size] (default 100) is
   intentionally simple and bounded. *)
let percentile_locked state pct =
  match state.latency_ring with
  | None -> None
  | Some ring when state.latency_count = 0 -> ignore ring; None
  | Some ring ->
    let n = state.latency_count in
    let buf = Array.sub ring 0 n in
    Array.sort Float.compare buf;
    if n = 1 then Some buf.(0)
    else
      let rank = pct *. float_of_int (n - 1) in
      let lo = int_of_float (Float.floor rank) in
      let hi = int_of_float (Float.ceil rank) in
      if lo = hi then Some buf.(lo)
      else
        let frac = rank -. float_of_int lo in
        Some (buf.(lo) *. (1.0 -. frac) +. buf.(hi) *. frac)

(* Average of populated confidence ring values.  [None] when no samples. *)
let avg_confidence_locked state =
  match state.confidence_ring with
  | None -> None
  | Some ring when state.confidence_count = 0 -> ignore ring; None
  | Some ring ->
    let n = state.confidence_count in
    let sum = ref 0.0 in
    for i = 0 to n - 1 do sum := !sum +. ring.(i) done;
    Some (!sum /. float_of_int n)

(* Average of populated cost ring values.  [None] when no samples. *)
let avg_cost_locked state =
  match state.cost_ring with
  | None -> None
  | Some ring when state.cost_count = 0 -> ignore ring; None
  | Some ring ->
    let n = state.cost_count in
    let sum = ref 0.0 in
    for i = 0 to n - 1 do sum := !sum +. ring.(i) done;
    Some (!sum /. float_of_int n)

(* Derive a cost score in [0.2, 1.0] from the average cost ring.
   Lower average cost = higher score.  Banded thresholds:
     avg < $0.01  → 1.0  (cheap)
     avg < $0.05  → 0.8
     avg < $0.10  → 0.6
     avg < $0.25  → 0.4
     otherwise    → 0.2  (expensive)
   Returns [None] when no cost samples exist so the caller defaults to 1.0. *)
let cost_score_of_avg = function
  | None -> None
  | Some avg ->
    let score =
      if avg < 0.01 then 1.0
      else if avg < 0.05 then 0.8
      else if avg < 0.10 then 0.6
      else if avg < 0.25 then 0.4
      else 0.2
    in
    Some score

let take_first_n n lst =
  let rec loop k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | x :: rest -> loop (k - 1) (x :: acc) rest
  in
  loop n [] lst

(** Composite health score: success_rate * speed_score * cost_score.
    - speed_score: p95 latency based. None = 1.0 (no penalty without data).
    - cost_score: banded thresholds from {!cost_score_of_avg} over the
      average cost ring populated by {!record_event} when [cost_usd]
      is provided. None = 1.0 (no penalty until samples accumulate).

    The function is total in the score arguments — callers receive the
    multiplied score regardless of whether samples exist. Read together
    with {!build_info_locked} which feeds [avg_cost_locked] through
    [cost_score_of_avg]; the dashboard's per-provider cost banding is
    therefore wired end-to-end (no longer a stub). *)

(* p95 latency band thresholds (milliseconds).  Each band maps to a
   speed_score multiplier: <=excellent → 1.0, <=good → 0.8,
   <=fair → 0.6, <=poor → 0.4, else → 0.2. *)
let p95_latency_excellent_ms = 5000.0
let p95_latency_good_ms = 15000.0
let p95_latency_fair_ms = 30000.0
let p95_latency_poor_ms = 60000.0

let compute_health_score ~success_rate ~p95_latency_ms_opt ~cost_score_opt =
  let speed_score =
    match p95_latency_ms_opt with
    | None -> 1.0
    | Some p95 ->
        if p95 <= p95_latency_excellent_ms then 1.0
        else if p95 <= p95_latency_good_ms then 0.8
        else if p95 <= p95_latency_fair_ms then 0.6
        else if p95 <= p95_latency_poor_ms then 0.4
        else 0.2
  in
  let cost_score = match cost_score_opt with None -> 1.0 | Some s -> s in
  success_rate *. speed_score *. cost_score

let build_info_locked ~now ~key state =
  let recent = prune_old_events now state.events in
  let total = List.length recent in
  let successes = List.length
      (List.filter (fun e -> e.outcome = Success) recent) in
  let rejected = List.length
      (List.filter (fun e -> e.outcome = Rejected) recent) in
  let rate =
    if total = 0 then 1.0
    else float_of_int successes /. float_of_int total
  in
  let in_cd = state.cooldown_until > now in
  let top_fingerprints =
    Hashtbl.fold (fun fp count acc -> (fp, count) :: acc)
      state.fingerprint_counts []
    |> List.sort (fun (_, a) (_, b) -> compare b a)
    |> take_first_n 3
  in
  let last_failure_at =
    if state.last_failure_at > 0.0 then Some state.last_failure_at else None
  in
  let p50_latency_ms = percentile_locked state 0.50 in
  let p95_latency_ms = percentile_locked state 0.95 in
  let avg_confidence = avg_confidence_locked state in
  let avg_cost_usd = avg_cost_locked state in
  let cost_score_opt = cost_score_of_avg avg_cost_usd in
  let health_score =
    compute_health_score ~success_rate:rate
      ~p95_latency_ms_opt:p95_latency_ms
      ~cost_score_opt
  in
  {
    provider_key = key;
    success_rate = rate;
    consecutive_failures = state.consecutive_failures;
    in_cooldown = in_cd;
    cooldown_expires_at = (if in_cd then Some state.cooldown_until else None);
    cooldown_cause =
      (if in_cd
       then Option.map outcome_kind_of_outcome state.cooldown_cause
       else None);
    events_in_window = total;
    rejected_in_window = rejected;
    top_fingerprints;
    last_failure_at;
    p50_latency_ms;
    p95_latency_ms;
    latency_samples = state.latency_count;
    avg_confidence;
    confidence_samples = state.confidence_count;
    avg_cost_usd;
    cost_samples = state.cost_count;
    health_score;
  }

let provider_info t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> None
    | Some state ->
      Some (build_info_locked ~now:(Unix.gettimeofday ()) ~key:provider_key state))

(** Evict tracker entries whose rolling window has fully aged out and
    whose cooldown has expired — they carry no information but would
    still appear on the dashboard as stale rows.  [consecutive_failures]
    is intentionally ignored: without an active cooldown or recent
    events, the counter is just a leftover that will be reset on the
    next call anyway. *)
let evict_idle t =
  with_lock t (fun () ->
    let now = Unix.gettimeofday () in
    let to_remove =
      Hashtbl.fold
        (fun key state acc ->
          let recent = prune_old_events now state.events in
          if recent = [] && state.cooldown_until <= now then key :: acc
          else acc)
        t.providers
        []
    in
    List.iter (Hashtbl.remove t.providers) to_remove;
    List.length to_remove)

let all_providers t =
  (* Opportunistic maintenance: reaping aged-out entries here keeps the
     dashboard's provider list stable without a separate maintenance
     fiber.  Dashboard polls every 30s, so this is bounded. *)
  let _ : int = evict_idle t in
  with_lock t (fun () ->
    let now = Unix.gettimeofday () in
    Hashtbl.fold
      (fun key state acc -> build_info_locked ~now ~key state :: acc)
      t.providers
      []
    |> List.sort (fun a b -> String.compare a.provider_key b.provider_key))

(* ── Outcome window queries ────────────────────── *)

(* [type outcome_kind] and [outcome_kind_of_outcome] are defined near [type
   outcome] so [build_info_locked] can use them. *)

let outcome_matches kind ev =
  (* Enumerate every [outcome_kind] x [outcome] pair so the compiler
     flags any new variant added to either type. Adding e.g. an
     [Outcome_circuit_break] kind without a matching [Circuit_break]
     outcome (or vice versa) would silently inherit [false] under the
     previous [_, _ -> false] catch-all, masking a probable mismatch.
     Same FSM Sparse Match anti-pattern as PRs #14716, #14762, #14790,
     #14806. *)
  match kind, ev.outcome with
  | Outcome_success, Success
  | Outcome_failure, Failure
  | Outcome_rejected, Rejected
  | Outcome_hard_quota, Hard_quota
  | Outcome_terminal_failure, Terminal_failure
  | Outcome_server_error, Server_error
  | Outcome_soft_rate_limited, Soft_rate_limited
  | Outcome_capacity_backpressure, Capacity_backpressure -> true
  | Outcome_success,
      (Failure | Rejected | Hard_quota | Terminal_failure | Server_error | Soft_rate_limited | Capacity_backpressure)
  | Outcome_failure,
      (Success | Rejected | Hard_quota | Terminal_failure | Server_error | Soft_rate_limited | Capacity_backpressure)
  | Outcome_rejected,
      (Success | Failure | Hard_quota | Terminal_failure | Server_error | Soft_rate_limited | Capacity_backpressure)
  | Outcome_hard_quota,
      (Success | Failure | Rejected | Terminal_failure | Server_error | Soft_rate_limited | Capacity_backpressure)
  | Outcome_terminal_failure,
      (Success | Failure | Rejected | Hard_quota | Server_error | Soft_rate_limited | Capacity_backpressure)
  | Outcome_server_error,
      (Success | Failure | Rejected | Hard_quota | Terminal_failure | Soft_rate_limited | Capacity_backpressure)
  | Outcome_soft_rate_limited,
      (Success | Failure | Rejected | Hard_quota | Terminal_failure | Server_error | Capacity_backpressure)
  | Outcome_capacity_backpressure,
      (Success | Failure | Rejected | Hard_quota | Terminal_failure | Server_error | Soft_rate_limited) -> false

(* Count [outcome] events recorded for [provider_key] within the last
   [window_s] seconds.  We piggyback on the same event ring used by
   [success_rate]; older events have already been pruned to
   [window_sec], so a caller-supplied [window_s] larger than that is
   silently truncated by the storage layer.  Returns 0 for unknown
   providers, non-positive [window_s], or no in-window matches. *)
let recent_outcome_count t ~provider_key ~outcome ~window_s =
  if window_s <= 0.0 then 0
  else
    with_lock t (fun () ->
      match Hashtbl.find_opt t.providers provider_key with
      | None -> 0
      | Some state ->
        let now = Unix.gettimeofday () in
        let cutoff = now -. window_s in
        List.fold_left
          (fun acc ev ->
             if ev.time >= cutoff && outcome_matches outcome ev then acc + 1
             else acc)
          0
          state.events)

(* ── Global singleton ─────────────────────────── *)

(** Global health tracker shared across all runtime calls in this process.
    Thread-safe via internal Mutex. *)
let global : t = create ()
