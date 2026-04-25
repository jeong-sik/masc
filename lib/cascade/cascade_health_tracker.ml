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

let getenv_with_alias ~primary ~deprecated =
  match Sys.getenv_opt primary with
  | Some v -> Some v
  | None ->
    (match Sys.getenv_opt deprecated with
     | Some _ as some ->
       if not (Hashtbl.mem deprecation_warned deprecated) then begin
         Hashtbl.add deprecation_warned deprecated ();
         Printf.eprintf
           "[warn] env var %s is deprecated; use %s (same semantics)\n%!"
           deprecated primary
       end;
       some
     | None -> None)

let read_float_setting ~primary ~deprecated ~default =
  match getenv_with_alias ~primary ~deprecated with
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

let read_int_setting ~primary ~deprecated ~default =
  match getenv_with_alias ~primary ~deprecated with
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

let finite_float value =
  match classify_float value with
  | FP_nan | FP_infinite -> false
  | FP_normal | FP_subnormal | FP_zero -> true

let read_bounded_float_setting ~primary ~default ~valid =
  let value = read_float_setting ~primary ~deprecated:"" ~default in
  if valid value && finite_float value then value
  else begin
    Log.Misc.warn "Out-of-range float for %s, using default %.2f"
      primary default;
    default
  end

let read_min_int_setting ~primary ~default ~min_value =
  let value = read_int_setting ~primary ~deprecated:"" ~default in
  if value >= min_value then value
  else begin
    Log.Misc.warn "Out-of-range int for %s=%d, using default %d"
      primary value default;
    default
  end

(** Rolling window duration in seconds.  Events older than this are
    discarded on read.  Default: 300s (5 minutes), matching OpenRouter's
    rolling percentile window. *)
let window_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_HEALTH_WINDOW_SEC"
    ~deprecated:"OAS_CASCADE_HEALTH_WINDOW_SEC"
    ~default:300.0

(** Number of consecutive failures before cooldown activates.
    Default: 3, matching LiteLLM's [allowed_fails] concept. *)
let cooldown_threshold =
  read_int_setting
    ~primary:"MASC_CASCADE_COOLDOWN_THRESHOLD"
    ~deprecated:"OAS_CASCADE_COOLDOWN_THRESHOLD"
    ~default:3

(** Cooldown duration in seconds.  During cooldown, the provider is
    skipped (not attempted).  Default: 60s.

    Trade-off vs LiteLLM's 30s default: 60s is 2x more conservative,
    prioritizing hot-loop avoidance over fast recovery.  A flapping
    provider that recovers within one cooldown window is re-entered on
    the next selection tick; at 30s, transient errors on the retry
    boundary can cause the cascade to thrash between providers.
    Override via [MASC_CASCADE_COOLDOWN_SEC] if recovery latency matters
    more than thrashing avoidance in your deployment. *)
let cooldown_sec =
  read_float_setting
    ~primary:"MASC_CASCADE_COOLDOWN_SEC"
    ~deprecated:"OAS_CASCADE_COOLDOWN_SEC"
    ~default:60.0

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

(** Phase 1 trust_score parameters (data-driven defaults from
    keeper decisions.jsonl analysis 2026-04-25, n=4040 across 14 keepers).

    Observed signal that informed each default:
    - 96% of same-fingerprint failures recur within 5 minutes
      → [persistent_window_sec=600] is more than enough
    - Top 5 fingerprints account for 74.5% of all errors
      → low [persistent_threshold=2] catches the dominant pattern
    - Max consecutive error streak = 108 (nick0cave keeper)
      → aggressive [decay_persistent=0.15] prevents oscillation
    - Successes are sparse (22.9% of decided turns)
      → faster [reward=0.15] to let healthy providers climb

    @since 0.175.0 *)
let trust_reward_on_success =
  read_bounded_float_setting
    ~primary:"MASC_CASCADE_TRUST_REWARD_ON_SUCCESS"
    ~default:0.15
    ~valid:(fun value -> value >= 0.0)

let trust_decay_transient =
  read_bounded_float_setting
    ~primary:"MASC_CASCADE_TRUST_DECAY_TRANSIENT"
    ~default:0.7
    ~valid:(fun value -> value >= 0.0 && value <= 1.0)

let trust_decay_persistent =
  read_bounded_float_setting
    ~primary:"MASC_CASCADE_TRUST_DECAY_PERSISTENT"
    ~default:0.15
    ~valid:(fun value -> value >= 0.0 && value <= 1.0)

let trust_ceiling =
  read_bounded_float_setting
    ~primary:"MASC_CASCADE_TRUST_CEILING"
    ~default:2.0
    ~valid:(fun value -> value >= 1.0)

let trust_persistent_threshold =
  read_min_int_setting
    ~primary:"MASC_CASCADE_TRUST_PERSISTENT_THRESHOLD"
    ~default:2
    ~min_value:1

let trust_persistent_window_sec =
  read_bounded_float_setting
    ~primary:"MASC_CASCADE_TRUST_PERSISTENT_WINDOW_SEC"
    ~default:600.0
    ~valid:(fun value -> value > 0.0)

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
type outcome = Success | Failure | Rejected | Hard_quota

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
  mutable trust_score: float;
  (* Phase 1 EWMA-style reputation in [0, trust_ceiling].  Initial 1.0
     (neutral).  Success: additive bump by [trust_reward_on_success]
     clipped at [trust_ceiling].  Failure: multiplicative decay by
     [trust_decay_transient] (one-shot) or [trust_decay_persistent] (same
     fingerprint within [trust_persistent_window_sec]).  Hard_quota: 0.0.
     Drives [effective_weight] in place of the rolling [success_rate].
     @since 0.175.0 *)
  mutable last_failure_fingerprint: string option;
  mutable last_failure_fingerprint_at: float;
  mutable same_fingerprint_count: int;
  (* Persistence detector: when a failure with fingerprint F arrives and
     [last_failure_fingerprint = Some F] within [trust_persistent_window_sec],
     [same_fingerprint_count] is incremented.  When [count >=
     trust_persistent_threshold] the failure is classified persistent
     (heavier decay).  Reset on different fingerprint or window expiry. *)
}

type t = {
  providers: (string, provider_state) Hashtbl.t;
  mu: Stdlib.Mutex.t;
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
      trust_score = 1.0;
      last_failure_fingerprint = None;
      last_failure_fingerprint_at = 0.0;
      same_fingerprint_count = 0;
    } in
    Hashtbl.replace t.providers key s;
    s

(* Build a stable fingerprint from caller-provided classification.
   Format: "kind|hash8(reason)" — kind defaults to "unclassified",
   hash suffix is omitted when reason is absent or empty.  Hash is
   MD5-truncated to 8 hex chars: collision-tolerant for an
   observability-only counter. *)
let make_fingerprint ?error_kind ?error_reason () =
  let kind =
    match error_kind with
    | Some k when String.trim k <> "" -> String.trim k
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

(* Phase 1: classify a fresh failure as transient vs persistent based on
   recurrence of the same fingerprint within [trust_persistent_window_sec].
   Returns [true] when the post-update count crosses
   [trust_persistent_threshold].  Mutates the persistence tracker fields. *)
let bump_persistence_locked state ~now ~fp =
  let same_recent =
    match state.last_failure_fingerprint with
    | Some prev ->
      String.equal prev fp
      && now -. state.last_failure_fingerprint_at
         < trust_persistent_window_sec
    | None -> false
  in
  if same_recent then
    state.same_fingerprint_count <- state.same_fingerprint_count + 1
  else
    state.same_fingerprint_count <- 1;
  state.last_failure_fingerprint <- Some fp;
  state.last_failure_fingerprint_at <- now;
  state.same_fingerprint_count >= trust_persistent_threshold

let apply_trust_failure_locked state ~persistent =
  let decay =
    if persistent then trust_decay_persistent
    else trust_decay_transient
  in
  let next = state.trust_score *. decay in
  (* Numerical floor: tiny positive trust still rounds to weight=1 via
     [max 1] in [effective_weight], so allow it to bottom out at 0.0
     when decay drives it below a meaningful threshold.  Saves floats
     from drifting into denormals on long persistent streaks. *)
  state.trust_score <-
    if next < 0.001 then 0.0 else next

let apply_trust_success_locked state =
  let next = state.trust_score +. trust_reward_on_success in
  state.trust_score <-
    if next > trust_ceiling then trust_ceiling else next

let record t ~provider_key ~outcome ?error_kind ?error_reason ~now () =
  with_lock t (fun () ->
    let state = get_or_create_state t provider_key in
    let event = { time = now; outcome } in
    state.events <- event :: prune_old_events now state.events;
    let bump_failure_fp () =
      let fp = make_fingerprint ?error_kind ?error_reason () in
      bump_fingerprint state fp;
      state.last_failure_at <- now;
      bump_persistence_locked state ~now ~fp
    in
    match outcome with
    | Success ->
      state.consecutive_failures <- 0;
      (* Clear cooldown on success — provider recovered *)
      state.cooldown_until <- 0.0;
      (* Phase 1: reward trust and reset persistence detector — a
         working call breaks the same-fingerprint streak. *)
      apply_trust_success_locked state;
      state.last_failure_fingerprint <- None;
      state.same_fingerprint_count <- 0
    | Failure | Rejected ->
      (* Rejected responses indicate unusable output (gate reject, empty
         body, schema miss).  Treat identically to Failure for cooldown
         and consecutive-failure tracking — a provider whose responses
         are consistently rejected is as useless as one that never
         responds.  The outcome tag is preserved in [events] so
         [provider_info] can count Rejected separately for dashboards. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      let persistent = bump_failure_fp () in
      apply_trust_failure_locked state ~persistent;
      if state.consecutive_failures >= cooldown_threshold then
        state.cooldown_until <- now +. cooldown_sec
    | Hard_quota ->
      (* Hard-quota errors (balance depleted, quota exceeded, resource
         exhausted) don't recover on short-window retries — set a long
         cooldown immediately regardless of [consecutive_failures].  We
         still increment the counter for dashboard continuity.  Preserve
         an already-longer cooldown (e.g. if two hard-quota events fire
         concurrently and the second arrives first in wall time). *)
      state.consecutive_failures <- state.consecutive_failures + 1;
      let _ : bool = bump_failure_fp () in
      (* Phase 1: hard_quota collapses trust to 0 — the long cooldown
         already prevents selection, but trust=0 keeps the cascade
         from reselecting this provider for the rest of this hour even
         if cooldown is somehow cleared. *)
      state.trust_score <- 0.0;
      let new_until = now +. hard_quota_cooldown_sec in
      if new_until > state.cooldown_until then
        state.cooldown_until <- new_until)

let record_success t ~provider_key =
  record t ~provider_key ~outcome:Success ~now:(Unix.gettimeofday ()) ()

let record_failure t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Failure ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

let record_rejected t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Rejected ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

let record_hard_quota t ~provider_key ?error_kind ?error_reason () =
  record t ~provider_key ~outcome:Hard_quota ?error_kind ?error_reason
    ~now:(Unix.gettimeofday ()) ()

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

(** Phase 1: read the trust_score, optimistic [1.0] for unknowns.
    Held under the same mutex as the writer for consistency. *)
let trust_score t ~provider_key =
  with_lock t (fun () ->
    match Hashtbl.find_opt t.providers provider_key with
    | None -> 1.0
    | Some state -> state.trust_score)

(** Compute effective weight for a provider.

    Phase 1: [effective_weight = max 1 (config_weight * clamp(trust, 0, ceiling))]

    Trust replaces the rolling success_rate as the weight driver because
    persistence-aware decay (data-calibrated 2026-04-25, n=4040) produces
    a more honest signal than a 5-min rolling average that re-promotes
    rate-limited providers within seconds.  The [success_rate] field
    stays in [provider_info] for dashboard observability.

    Providers in cooldown get weight 0 (skipped).  Unknown providers
    get their full config weight (optimistic).  The [max 1] floor
    guarantees a barely-trusted provider still gets occasional retry
    chances; [cooldown_threshold] (3 consecutive failures) is the
    hard "stop trying" mechanism. *)
let effective_weight t ~provider_key ~config_weight =
  if is_in_cooldown t ~provider_key then 0
  else
    let trust = trust_score t ~provider_key in
    let clamped =
      if trust < 0.0 then 0.0
      else if trust > trust_ceiling then trust_ceiling
      else trust
    in
    max 1 (int_of_float (float_of_int config_weight *. clamped))

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
      Printf.sprintf
        "%s: %d/%d ok (%.0f%%) consec_fail=%d trust=%.2f cooldown=%b"
        provider_key successes total
        (if total > 0 then 100.0 *. float_of_int successes /. float_of_int total else 100.0)
        state.consecutive_failures
        state.trust_score
        in_cd)

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
  trust_score : float;
  same_fingerprint_count : int;
}

let take_first_n n lst =
  let rec loop k acc = function
    | [] -> List.rev acc
    | _ when k <= 0 -> List.rev acc
    | x :: rest -> loop (k - 1) (x :: acc) rest
  in
  loop n [] lst

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
    trust_score = state.trust_score;
    same_fingerprint_count = state.same_fingerprint_count;
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

(* ── Global singleton ─────────────────────────── *)

(** Global health tracker shared across all cascade calls in this process.
    Thread-safe via internal Mutex. *)
let global : t = create ()
