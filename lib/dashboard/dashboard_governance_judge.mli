(** Dashboard_governance_judge — periodic governance
    judgments daemon: state cache, refresh fiber,
    runtime-status snapshot rendering, and the
    response-model classification used by the empty-model
    metric.

    External surface:
    - {b types} ({!runtime_snapshot}, {!state},
      {!compute_in_flight_state}, {!governance_model_source})
      reached as records or type refs by [dashboard_governance.ml],
      [dashboard_http_monitoring.ml], the runtime-status
      regression test, and the response-model regression
      test.
    - {b read paths} ({!fresh_judgments_json},
      {!runtime_status}, {!runtime_status_at}, {!read_in_flight})
      consumed by the dashboard JSON producer, HTTP monitoring
      route, and the white-box regression suite.
    - {b state lifecycle} ({!get_state}, {!with_lock},
      {!mark_refresh_failure}, {!mark_compute_start},
      {!mark_compute_finish}, {!refresh_once}, {!start})
      consumed by the bootstrap loop + the white-box
      regression suite.  The compute lifecycle pair
      ({!mark_compute_start} / {!mark_compute_finish})
      replaced the [Eio.Switch.on_release] counter that
      PR #20479 added; see {!compute_in_flight_state} for
      the typed invariant.
    - {b classification} ({!resolve_governance_model_used},
      {!governance_model_source_to_string},
      {!level_of_compute_outcome}) consumed by the
      per-cycle empty-model regression test and the
      compute-telemetry severity regression.
    - {b daemon identity} ({!keeper_name}) embedded into
      the dashboard envelope.

    Internal helpers stay private at this boundary
    ([governance_response_model_empty_metric] +
    auto-registration block, [governance_dir] /
    [judgments_path] / [judgments_store_cache] /
    [states] singleton tables, [outer_mu] /
    [with_outer_rw], [get_judgments_store],
    [ensure_dir], [iso_of_unix] / [parse_iso_opt] /
    [now_iso] / [option_to_yojson] re-exports,
    [interval_sec] / [cache_ttl_sec] /
    [empty_judgment_reload_cooldown_sec] /
    [enabled] config readers,
    [backoff_status] / [status_*] string constants,
    [contains_substring], [degraded_reason_of_error],
    [cached_judgments_still_fresh] /
    [cached_result_still_fresh],
    [mark_fresh_cache_served], [key_of] /
    [judgment_key] / [judgment_generated_at] /
    [normalize_disk_recommended_action],
    [load_judgments_into_table] /
    [load_latest_from_disk] / [latest_judgments],
    [parse_string_list] / [normalize_text] /
    [normalize_allowed_tool_name] / [allowed_tool],
    [parse_recommended_action] / [parse_item_judgment],
    [prompt_for_facts], [compute_judgments],
    [append_judgments], [should_backoff]). *)

(** {1 Runtime snapshot} *)

type runtime_snapshot = {
  judge_online : bool;
  refreshing : bool;
  status : string;
  degraded_reason : string option;
  cached_judgments_visible : bool;
  generated_at : string option;
  generated_at_unix : float option;
  expires_at : string option;
  expires_at_unix : float option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
  compute_in_flight : int;
  last_compute_duration_sec : float option;
  last_compute_timeout_sec : float option;
  last_compute_outcome : string option;
  last_compute_reason : string option;
}
(** Snapshot of the daemon's externally-visible runtime
    state.  Constructed by {!runtime_status_at} under
    [with_lock] so every field is consistent with one
    observation of the underlying {!state}.  [model_used]
    is a legacy compatibility field and is redacted to
    [None] on this public snapshot.  [compute_in_flight]
    is a derived value: the daemon's {b source of truth}
    for the in-flight cycle is the state machine in
    {!state.compute_state} (an [Idle | In_flight _] variant
    carrying the cycle's [started_at] timestamp and
    monotonically increasing [cycle_id]).  This snapshot
    field is materialized on read via {!read_in_flight},
    which always reflects the current variant: [Idle] → 0,
    [In_flight _] → 1.  The state machine has no dependency
    on a callback firing, so a parent-fibre cancellation
    cannot leave a stuck positive — the next
    [mark_compute_start] / [mark_compute_finish] transition
    is the only writer. *)

type compute_in_flight_state =
  | Idle
  | In_flight of {
      started_at : float;
      cycle_id : int;
    }
(** State of the in-flight compute cycle.  Replaces the
    previous [int] counter, which was a workaround: a
    fire-and-forget [Eio.Switch.on_release] callback could
    over-decrement or under-decrement under parent-fibre
    cancellation, leaving the counter stuck.  With this
    state machine, transitions are made explicitly by
    {!mark_compute_start} (Idle → In_flight, allocating a
    fresh [cycle_id] from {!state.next_cycle_id}) and
    {!mark_compute_finish} (In_flight → Idle).  There is no
    callback-driven decrement — the state itself is the
    source of truth, and the [int] exposed via
    {!read_in_flight} is a pure projection. *)

(** {1 Daemon mutable state} *)

type state = {
  mutex : Eio.Mutex.t;
  mutable started : bool;
  mutable refreshing : bool;
  mutable judge_online : bool;
  mutable runtime_status : string;
  mutable degraded_reason : string option;
  mutable generated_at_unix : float option;
  mutable expires_at_unix : float option;
  mutable generated_at : string option;
  mutable expires_at : string option;
  mutable model_used : string option;
  mutable last_error : string option;
  mutable compute_state : compute_in_flight_state;
  mutable next_cycle_id : int;
  mutable last_compute_duration_sec : float option;
  mutable last_compute_timeout_sec : float option;
  mutable last_compute_outcome : string option;
  mutable last_compute_reason : string option;
  mutable next_compute_after_unix : float option;
  mutable last_disk_load_unix : float option;
  mutable judgments : (string, Yojson.Safe.t) Hashtbl.t;
}
(** Mutable in-memory daemon state.  One instance per
    [base_path] is cached in the singleton table and
    handed out by {!get_state}.

    Pinned as a concrete record because the regression
    suite ([test/test_dashboard_governance.ml]) reaches
    the mutable fields directly under {!with_lock} to
    seed cache state for individual scenarios.  The
    [judgments] table and [mutex] are exposed alongside
    them for the same reason.  The compute telemetry
    ([compute_state] + the last duration / outcome / reason
    triple) replaces the #11079 [int] counter.  The
    [next_cycle_id] field drives [mark_compute_start]'s
    monotonic tag.  [next_compute_after_unix] records
    timeout backoff for advisory judge retries.  Every other
    reader goes through {!runtime_status} /
    {!fresh_judgments_json}. *)

val read_in_flight : state -> int
(** Read the in-flight count as a pure projection of
    {!state.compute_state}: [Idle] → [0], [In_flight _] → [1].
    Does not mutate state and does not call any Eio
    probe — the previous design attempted to use
    [Eio.Switch.is_closed] to lazily recover, but the
    probe is not a total correctness primitive under
    parent-fibre cancellation.  The state machine itself
    is the source of truth; this projection is just an
    [int] view.  Thread-safe under [Eio.Mutex.with_lock]. *)

val mark_compute_start : state -> int
(** Transition {!state.compute_state} from [Idle] to
    [In_flight], allocating a fresh [cycle_id] from
    {!state.next_cycle_id} and stamping [started_at] with
    the wall clock.  If the previous state is already
    [In_flight _] (i.e. a prior cycle never finished
    cleanly), emits a governance-routine log and replaces
    the state with the new cycle — the typed invariant
    holds regardless.  Returns the allocated [cycle_id].
    Publishes the [governance_compute_in_flight] gauge
    at [1.0].  Thread-safe under [Eio.Mutex.with_lock]. *)

val mark_compute_finish :
  state ->
  cycle_id:int ->
  started_at:float ->
  outcome:string ->
  reason:string ->
  float * int
(** Transition {!state.compute_state} from [In_flight _]
    back to [Idle], record the terminal-cycle telemetry
    ([last_compute_duration_sec], [last_compute_outcome],
    [last_compute_reason]), publish the
    [governance_compute_in_flight] gauge at [0.0], emit
    the [refresh_once: compute_judgments telemetry …]
    line at the outcome-derived severity, and observe the
    duration histogram.  [cycle_id] is the value returned
    by the matching {!mark_compute_start}; a finish whose
    [cycle_id] does not match the current [In_flight] cycle
    (because a newer cycle replaced it) is logged at
    [routine] and discarded.  [started_at] is the wall clock
    captured at the matching {!mark_compute_start}; the
    duration is clamped to [>= 0] so a backwards clock
    adjustment (NTP step, manual change) cannot inject a
    negative value.  Idempotent on [Idle]: a finish
    without a matching start is logged at [routine] and
    does not error (a user-site exception path can re-raise
    after partial teardown).  Returns
    [(duration_sec, in_flight_after)] where [in_flight_after]
    is the post-transition projection (always [0] on
    success).  Thread-safe under [Eio.Mutex.with_lock]. *)

(** {1 Response-model classification} *)

type governance_model_source =
  | Response_model
  | Telemetry_resolved
  | Unknown_source
(** Source of the model id used for a governance
    judgment.  Used by the per-cycle empty-model metric
    to attribute classifications to fall-through paths. *)

val governance_model_source_to_string :
  governance_model_source -> string
(** [Response_model] → ["response_model"];
    [Telemetry_resolved] → ["telemetry_resolved"];
    [Unknown_source] → ["unknown_source"]. *)

val resolve_governance_model_used :
  raw_model:string ->
  canonical_model_id:string option ->
  string * governance_model_source
(** Picks the internal model id for empty-model diagnostics.
    [raw_model] (trimmed non-empty) wins for classification; otherwise
    falls back to [canonical_model_id], otherwise the unknown source branch.
    Evidence-backed model ids are projected to the neutral [runtime] lane so
    dashboard state does not expose concrete provider/model identity. Missing
    evidence returns [Boundary_redaction.unknown_model_label] instead of
    fabricating runtime evidence. *)

type governance_response_parse_failure =
  | Structural_error of string
(** Failure class for governance judge response parsing.
    [Structural_error reason] means the response was not strict JSON
    or violated the judge output contract. *)

val parse_governance_response_for_testing :
  raw_text:string ->
  generated_at:string ->
  expires_at:string ->
  model_used:string ->
  (Yojson.Safe.t list, governance_response_parse_failure) result
(** Parses and validates a governance judge response without
    mutating metrics or daemon state.  Exposed so regression
    tests can prove malformed [guardrail_state] output fails
    closed instead of silently producing a distorted judgment.
    [model_used] remains accepted for legacy call sites, but
    parsed public rows redact it to [null]. *)

(** {1 Compute-finish log severity} *)

val level_of_compute_outcome :
  outcome:string -> reason:string -> Log.level
(** Severity for the [refresh_once: compute_judgments telemetry outcome=…]
    line, derived from the compute outcome rather than hardcoded.  A genuine
    ["error"] outcome (degraded with auto-recovery via the next refresh) is
    [Log.Warn]; a graceful cancellation ([reason="cancelled"]) and success are
    [Log.Info].  Exposed so the regression suite can prove an errored compute is
    not emitted at [Info] (docs/spec/18-log-severity-taxonomy.md § 3.6). *)

(** {1 Daemon identity} *)

val keeper_name : string
(** ["governance-judge"] — the synthetic keeper name the
    daemon reports under in the dashboard envelope. *)

(** {1 State lifecycle} *)

val get_state : string -> state
(** Returns the {!state} record for [base_path], creating
    a fresh one on first access.  Backed by a process-wide
    singleton table; subsequent calls return the same
    record so [with_lock]-guarded mutations are visible. *)

val with_lock : state -> (unit -> 'a) -> 'a
(** Runs [f] under [state.mutex] in protected RW mode.
    Test scaffolding mutates [state] fields under this
    lock; production paths use it implicitly through
    {!runtime_status_at} and {!refresh_once}. *)

val mark_refresh_failure :
  now_ts:float -> state -> message:string -> unit
(** Transitions the daemon out of [refreshing] and
    records [message] as the most recent error.  Preserves
    the cached judgments while their TTL is still valid
    (degrades to stale-but-visible rather than flipping
    offline immediately). *)

val mark_compute_start : state -> int
(** Transitions the daemon's [compute_state] from [Idle]
    to [In_flight { … }] and returns the new monotonic
    [cycle_id].  If a previous [In_flight] cycle is still
    recorded, it is replaced (with a [Log.Governance.routine]
    note) — the daemon's loop is sequential, so this
    represents an anomaly case rather than normal flow.

    Updates the [governance_compute_in_flight] gauge to [1].
    Exposed because the regression suite
    ([test/test_dashboard_governance.ml] test 5) drives the
    state machine directly to assert on cycle-id
    monotonicity and the Idle→In_flight transition. *)

val mark_compute_finish :
  state -> cycle_id:int -> started_at:float -> outcome:string -> reason:string -> float * int
(** Resets the daemon's [compute_state] to [Idle] and emits
    the terminal telemetry for one cycle: duration observed
    from [started_at] (clamped to [\>= 0.0]), the
    [governance_compute_total] counter, and the
    [governance_compute_duration] histogram.  The
    [governance_compute_in_flight] gauge is set to [0].

    [cycle_id] is the value returned by the matching
    {!mark_compute_start}; a finish whose [cycle_id] does
    not match the current [In_flight] cycle (because a newer
    cycle replaced it) is logged at [routine] and discarded.

    Returns [(duration_sec, in_flight_after)] where
    [in_flight_after] is the post-reset [read_in_flight]
    projection (always [0] in a healthy cycle; the value
    is surfaced so the embedded [in_flight_after=…] log
    line and the histogram can both read the same
    under-lock snapshot).  A stray call (state already
    [Idle]) is a defensive no-op with a
    [Log.Governance.routine] note — the user-site
    exception path can re-raise after partial teardown,
    so this is the only path that is allowed to drop
    the cycle tag without panicking. *)

val read_in_flight : state -> int
(** Projects the [compute_state] field to the [int] view
    used by the runtime snapshot.  Returns [0] for [Idle]
    and [1] for [In_flight _].  Exposed because the
    regression suite drives the state machine directly to
    assert the [0/1] surface stays in sync with the
    underlying enum.  All other readers go through
    {!runtime_status_at}.  Kept as a [val] (not inlined
    into [runtime_status]) to preserve the
    "single read of the state under one lock" invariant
    that test 5 depends on. *)

(** {1 Read paths} *)

val fresh_judgments_json :
  base_path:string -> limit:int -> Yojson.Safe.t list
(** Returns the [limit] most recent judgments whose
    [expires_at] (when present) has not passed.  Sorted
    by descending [generated_at]. *)

val runtime_status_at :
  now_ts:float -> string -> runtime_snapshot
(** Renders the {!runtime_snapshot} for [base_path] using
    the supplied wall-clock instant.  Test-friendly
    timestamp-injection variant of {!runtime_status}. *)

val runtime_status : string -> runtime_snapshot
(** [runtime_status base_path] is
    [runtime_status_at ~now_ts:(Unix.gettimeofday ()) base_path]. *)

(** {1 Refresh fiber} *)

val refresh_once :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  base_path:string ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit
(** Runs one refresh cycle.  Skips when the cached result
    is still fresh; backs off when the per-host slot
    pool is saturated; otherwise computes new judgments
    and appends them.  Logged via [Log.Governance.*]. *)

val start :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_path:string ->
  masc_tools:Masc_domain.tool_schema list ->
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.result) ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit ->
  unit
(** Starts the periodic refresh fiber.  Idempotent — a
    second call against the same [base_path] returns
    without forking a new daemon.  No-op when the
    [governance_judge_enabled] config gate is off. *)
