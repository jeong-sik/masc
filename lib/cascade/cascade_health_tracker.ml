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
}

type t = {
  providers: (string, provider_state) Hashtbl.t;
  mu: Eio.Mutex.t;
}

(* ── Constructor ──────────────────────────────── *)

let create () : t = {
  providers = Hashtbl.create 8;
  mu = Eio.Mutex.create ();
}

let with_lock t f =
  Eio.Mutex.use_rw ~protect:true t.mu (fun () -> f ())

let get_or_create_state t key =
  match Hashtbl.find_opt t.providers key with
  | Some s -> s
  | None ->
    let s = {
      events = [];
      consecutive_failures = 0;
      cooldown_until = 0.0;
    } in
    Hashtbl.replace t.providers key s;
    s

(* ── Recording ────────────────────────────────── *)

let prune_old_events now events =
  let cutoff = now -. window_sec in
  List.filter (fun e -> e.time >= cutoff) events

let record t ~provider_key ~outcome ~now =
  with_lock t (fun () ->
    let state = get_or_create_state t provider_key in
    let event = { time = now; outcome } in
    state.events <- event :: prune_old_events now state.events;
    match outcome with
    | Success ->
      state.consecutive_failures <- 0;
      (* Clear cooldown on success — provider recovered *)
      state.cooldown_until <- 0.0
    | Failure | Rejected ->
      (* Rejected responses indicate unusable output (gate reject, empty
         body, schema miss).  Treat identically to Failure for cooldown
         and consecutive-failure tracking — a provider whose responses
         are consistently rejected is as useless as one that never
         responds.  The outcome tag is preserved in [events] so
         [provider_info] can count Rejected separately for dashboards. *)
      state.consecutive_failures <- state.consecutive_failures + 1;
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
      let new_until = now +. hard_quota_cooldown_sec in
      if new_until > state.cooldown_until then
        state.cooldown_until <- new_until)

let record_success t ~provider_key =
  record t ~provider_key ~outcome:Success ~now:(Unix.gettimeofday ())

let record_failure t ~provider_key =
  record t ~provider_key ~outcome:Failure ~now:(Unix.gettimeofday ())

let record_rejected t ~provider_key =
  record t ~provider_key ~outcome:Rejected ~now:(Unix.gettimeofday ())

let record_hard_quota t ~provider_key =
  record t ~provider_key ~outcome:Hard_quota ~now:(Unix.gettimeofday ())

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
}

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
  {
    provider_key = key;
    success_rate = rate;
    consecutive_failures = state.consecutive_failures;
    in_cooldown = in_cd;
    cooldown_expires_at = (if in_cd then Some state.cooldown_until else None);
    events_in_window = total;
    rejected_in_window = rejected;
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
