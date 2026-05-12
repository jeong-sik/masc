(** Reactive health tracking for cascade providers.

    Tracks per-provider success/failure rates using a rolling time window.
    Providers in cooldown (consecutive failures exceed threshold) are
    temporarily skipped.  Health data feeds into weighted cascade selection
    via {!effective_weight}.

    Design: LiteLLM cooldown + OpenRouter rolling-window hybrid.
    See RFC-OAS-006 Phase 2.

    Thread safety: uses [Stdlib.Mutex] (not Eio.Mutex) for cross-fiber
    safety without Eio dependency in the hot path.  Critical sections are
    small (record append + list scan).

    @since 0.137.0 *)

(* ── Configuration ────────────────────────────── *)

(** One-time deprecation warning for legacy OAS_CASCADE_* env vars.
    The cascade routing layer was migrated from OAS to MASC in v0.149.0
    (see docs/rfc/RFC-OAS-006-weighted-cascade-routing.md + follow-ups);
    the env var prefix stayed [OAS_CASCADE_*] by drift.  We accept both
    during the transition and emit a one-shot warning per deprecated
    key so operators can update their deployment config. *)
let deprecation_warned : (string, unit) Hashtbl.t = Hashtbl.create 4

let getenv_with_alias ~primary ?deprecated () =
  match Sys.getenv_opt primary with
  | Some v -> Some v
  | None ->
    (match deprecated with
     | None -> None
     | Some dep ->
       (match Sys.getenv_opt dep with
        | Some _ as some ->
          if not (Hashtbl.mem deprecation_warned dep) then begin
            Hashtbl.add deprecation_warned dep ();
            Log.Misc.warn
              "env var %s is deprecated; use %s (same semantics)"
              dep primary
          end;
          some
        | None -> None))

let read_float_setting ~primary ?deprecated ~default () =
  match getenv_with_alias ~primary ?deprecated () with
  | None -> default
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then default
    else
      match Safe_ops.float_of_string_safe trimmed with
      | Some value -> value
      | None ->
        Log.Misc.warn "Invalid float for %s=%S, using default %.1f"
          primary raw default;
        default

let read_int_setting ~primary ?deprecated ~default () =
  match getenv_with_alias ~primary ?deprecated () with
  | None -> default
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then default
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some value -> value
      | None ->
        Log.Misc.warn "Invalid int for %s=%S, using default %d"
          primary raw default;
        default

(** Rolling window duration in seconds.  Events older than this are
    discarded on read.  Default: 300s (5 minutes), matching OpenRouter's
    rolling percentile window. *)
let window_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_HEALTH_WINDOW_SEC"
    ~deprecated:"OAS_CASCADE_HEALTH_WINDOW_SEC"
    ~default:300.0
    ()

(** Number of consecutive failures before cooldown activates.
    Default: 3, matching LiteLLM's [allowed_fails] concept. *)
let cooldown_threshold =
  read_int_setting
    ~primary:"MASC_CASCADE_COOLDOWN_THRESHOLD"
    ~deprecated:"OAS_CASCADE_COOLDOWN_THRESHOLD"
    ~default:3
    ()

(** Cooldown duration in seconds.  During cooldown, the provider is
    skipped (not attempted).  Default: 30s, matching the provider
    circuit-breaker OPEN threshold used by the cascade.  Hard quota and
    terminal provider errors use separate long cooldowns. *)
let cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_COOLDOWN_SEC"
    ~default:30.0
    ()

(** RFC-0037 §4.5: local providers (ollama, llama.cpp, etc.) get a
    more generous failure budget than remote APIs.  Local probes are
    flaky by nature (process startup, model load latency, transient
    /api/ps stalls) but recover within seconds — locking them out for
    the full [cooldown_sec] window denies the keeper a viable provider
    when the remote alternatives are also failing.

    Defaults: 5 consecutive failures (vs remote 3), 10s cooldown (vs
    remote 30s).  Both are env-tunable and floored at 1 / 1.0
    respectively to prevent zero-value misconfiguration from disabling
    cooldown entirely.

    Provider classification uses {!Runtime_catalog.is_local_provider},
    the same primitive cascade_runtime already consumes — no new
    classifier introduced. *)
let local_cooldown_threshold =
  Int.max 1
    (read_int_setting
       ~primary:"MASC_LOCAL_COOLDOWN_THRESHOLD"
       ~default:5
       ())

let local_cooldown_sec =
  Float.max 1.0
    (read_float_setting
       ~primary:"MASC_LOCAL_COOLDOWN_SEC"
       ~default:10.0
       ())

let cooldown_config_for ~provider_key =
  if Runtime_catalog.is_local_provider provider_key then
    (local_cooldown_threshold, local_cooldown_sec)
  else
    (cooldown_threshold, cooldown_sec)

(** Cooldown duration for provider calls classified as hard-quota exhaustion
    (account balance depleted, monthly quota reached, resource exhausted).
    Unlike transient 429s, hard-quota errors will not recover within a short
    window — retrying on the next cascade tick just wastes a turn.  This
    cooldown is applied immediately on the first such error (no threshold)
    and is significantly longer than {!cooldown_sec}.

    Default: 3600s (1h), matching the typical granularity of quota/billing
    reset cycles.  Override via [MASC_CASCADE_HARD_QUOTA_COOLDOWN_SEC] if
    your provider's quota window is shorter (e.g. per-minute tier limits
    that happen to trigger hard-quota indicator strings).

    @since 0.161.0 *)
let hard_quota_cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_HARD_QUOTA_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_HARD_QUOTA_COOLDOWN_SEC"
    ~default:3600.0
    ()

(** Cooldown duration for provider calls classified as terminal structural
    failures, where retrying the same provider on the next cascade tick is
    expected to reproduce the same failure until operator/runtime state changes.
    Examples: Kimi CLI reporting a resumable session conflict instead of
    accepting a fresh non-interactive invocation.

    This is separate from hard-quota so dashboards and future policy can
    distinguish "account exhausted" from "adapter/session state is wedged",
    while both use the same immediate long-cooldown behavior.

    Default: 3600s (1h). *)
let terminal_failure_cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_TERMINAL_FAILURE_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_TERMINAL_FAILURE_COOLDOWN_SEC"
    ~default:3600.0
    ()

(** Default cooldown applied immediately on a transient HTTP 429.  See the
    [.mli] for the design rationale; the short default (10s) is calibrated
    so that a single 429 deprioritizes the provider for the remainder of
    the current cascade cycle without locking it out long enough to disturb
    the rolling success-rate window. *)
let soft_rate_limit_cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_SOFT_RATE_LIMIT_COOLDOWN_SEC"
    ~default:10.0
    ()

(** Upper clamp for caller-supplied Retry-After.  Anything past 2 minutes
    is "hard quota in disguise" and should be classified as such by the
    caller — see {!record_soft_rate_limited}.  The clamp protects us from
    silently honoring a 3600-second Retry-After that would otherwise
    blackhole the provider for an hour under transient-error semantics. *)
let soft_rate_limit_max_clamp_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_SOFT_RATE_LIMIT_MAX_CLAMP_SEC"
    ~default:120.0
    ()

(** Per-provider ring buffer size for recent successful-call latency.
    Default 100 — strategy decisions only need a "recent" sense of
    response speed, not the full distribution.  Sort cost on every
    [provider_info] read is O(n log n) on the populated portion of the
    ring, which at n=100 is trivially small.

    Negative or zero disables latency tracking entirely: the ring is
    treated as size 0 (no allocation, no samples retained, [p50_latency_ms]
    and [p95_latency_ms] always [None]).  Useful as an env-level kill
    switch if downstream metric pressure ever surfaces.

    Env: [MASC_CASCADE_LATENCY_RING_SIZE]. *)
let latency_ring_size =
  match Sys.getenv_opt "MASC_CASCADE_LATENCY_RING_SIZE" with
  | None -> 100
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 100
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some n -> n
      | None ->
        Log.Misc.warn
          "Invalid int for MASC_CASCADE_LATENCY_RING_SIZE=%S, using default 100"
          raw;
        100


let confidence_ring_size =
  match Sys.getenv_opt "MASC_CASCADE_CONFIDENCE_RING_SIZE" with
  | None -> 100
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 100
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some n -> n
      | None ->
        Log.Misc.warn
          "Invalid int for MASC_CASCADE_CONFIDENCE_RING_SIZE=%S, using default 100"
          raw;
        100

let cost_ring_size =
  match Sys.getenv_opt "MASC_CASCADE_COST_RING_SIZE" with
  | None -> 100
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then 100
    else
      match Safe_ops.int_of_string_safe trimmed with
      | Some n -> n
      | None ->
        Log.Misc.warn
          "Invalid int for MASC_CASCADE_COST_RING_SIZE=%S, using default 100"
          raw;
        100


(* ── Types ────────────────────────────────────── *)

(* [Rejected] is the third outcome kind introduced in 0.160.0.  It
   represents "response arrived but the cascade's accept predicate
   rejected it" — behaviorally equivalent to [Failure] (same cooldown
   trigger, same success-rate impact) but visible to the dashboard so
   operators can tell a down provider apart from one whose outputs are
   consistently unusable. *)
(* [Hard_quota] is the fourth outcome kind introduced in 0.161.0.  It
   represents "provider returned a terminal quota-exhaustion error (balance
   0, monthly quota reached, resource exhausted)" — classified via OAS
   [Llm_provider.Retry.is_hard_quota].  Unlike [Failure], a single event
   triggers an immediate long cooldown ([hard_quota_cooldown_sec]); the
   [cooldown_threshold] does not apply because retry on the next cascade
   tick is pointless when the upstream account is out of credit. *)
(* [Terminal_failure] represents structural provider/adapter failures that are
   deterministic for the current runtime state.  A Kimi CLI resumable-session
   conflict is the motivating case: fallback is correct for the current call,
   but repeatedly attempting Kimi first on every later call only adds latency
   and silently degrades cascade diversity. *)
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
  | Soft_rate_limited

type event = {
  time: float;  (* Unix timestamp *)
  outcome: outcome;
}

type provider_state = {
  mutable events: event list;  (* newest first *)
  mutable consecutive_failures: int;
  mutable cooldown_until: float;  (* 0.0 = not in cooldown *)
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
   [provider_cooldown_remaining_sec_for_cascade → provider_info]
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
          Cascade_metrics.on_provider_cooldown
            ~provider:provider_key ~reason:"failure_threshold";
          Prometheus.observe_histogram Keeper_metrics.metric_keeper_provider_block_duration_sec
            ~labels:[("provider", provider_key)] cooldown_dur
        end
      end
    | Soft_rate_limited ->
      (* Transient HTTP 429.  Apply an immediate short cooldown so the
         current cascade cycle skips this provider for the next selection
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
        Cascade_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"soft_rate_limit";
        Prometheus.observe_histogram Keeper_metrics.metric_keeper_provider_block_duration_sec
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
        Cascade_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"hard_quota";
        Prometheus.observe_histogram Keeper_metrics.metric_keeper_provider_block_duration_sec
          ~labels:[("provider", provider_key)] hard_quota_cooldown_sec
      end
    | Terminal_failure ->
      (* Terminal structural errors are not quota exhaustion, but they have the
         same retry shape: the next cascade tick will hit the same provider
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
        Cascade_metrics.on_provider_cooldown
          ~provider:provider_key ~reason:"terminal_failure";
        Prometheus.observe_histogram Keeper_metrics.metric_keeper_provider_block_duration_sec
          ~labels:[("provider", provider_key)] terminal_failure_cooldown_sec
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

let record_soft_rate_limited t ~provider_key ?retry_after_s ?error_kind
    ?error_reason () =
  record t ~provider_key ~outcome:Soft_rate_limited ?error_kind ?error_reason
    ?retry_after_s ~now:(Unix.gettimeofday ()) ()

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
    should be skipped in cascade selection.

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
        false
      end)

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
    - cost_score: placeholder 1.0 (cost tracking not yet wired). *)
let compute_health_score ~success_rate ~p95_latency_ms_opt ~cost_score_opt =
  let speed_score =
    match p95_latency_ms_opt with
    | None -> 1.0
    | Some p95 ->
        if p95 <= 5000.0 then 1.0
        else if p95 <= 15000.0 then 0.8
        else if p95 <= 30000.0 then 0.6
        else if p95 <= 60000.0 then 0.4
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
  Prometheus.set_gauge Prometheus.metric_cascade_provider_health_score
    ~labels:[ ("provider_key", key) ]
    health_score;
  {
    provider_key = key;
    success_rate = rate;
    consecutive_failures = state.consecutive_failures;
    in_cooldown = in_cd;
    cooldown_expires_at = (if in_cd then Some state.cooldown_until else None);
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

type outcome_kind =
  | Outcome_success
  | Outcome_failure
  | Outcome_rejected
  | Outcome_hard_quota
  | Outcome_terminal_failure
  | Outcome_soft_rate_limited

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
  | Outcome_soft_rate_limited, Soft_rate_limited -> true
  | Outcome_success,
      (Failure | Rejected | Hard_quota | Terminal_failure | Soft_rate_limited)
  | Outcome_failure,
      (Success | Rejected | Hard_quota | Terminal_failure | Soft_rate_limited)
  | Outcome_rejected,
      (Success | Failure | Hard_quota | Terminal_failure | Soft_rate_limited)
  | Outcome_hard_quota,
      (Success | Failure | Rejected | Terminal_failure | Soft_rate_limited)
  | Outcome_terminal_failure,
      (Success | Failure | Rejected | Hard_quota | Soft_rate_limited)
  | Outcome_soft_rate_limited,
      (Success | Failure | Rejected | Hard_quota | Terminal_failure) -> false

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

(** Global health tracker shared across all cascade calls in this process.
    Thread-safe via internal Mutex. *)
let global : t = create ()
