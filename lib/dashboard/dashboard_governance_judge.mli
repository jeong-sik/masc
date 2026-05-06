(** Dashboard_governance_judge — periodic governance
    judgments daemon: state cache, refresh fiber,
    runtime-status snapshot rendering, and the
    response-model classification used by the empty-model
    metric.

    External surface:
    - {b types} ({!runtime_snapshot}, {!state},
      {!governance_model_source}) reached as records or
      type refs by [dashboard_governance.ml],
      [dashboard_http_monitoring.ml], the runtime-status
      regression test, and the response-model regression
      test.
    - {b read paths} ({!fresh_judgments_json},
      {!runtime_status}, {!runtime_status_at}) consumed
      by the dashboard JSON producer and HTTP monitoring
      route.
    - {b state lifecycle} ({!get_state}, {!with_lock},
      {!mark_refresh_failure}, {!refresh_once}, {!start})
      consumed by the bootstrap loop + the white-box
      regression suite.
    - {b classification} ({!resolve_governance_model_used},
      {!governance_model_source_to_string}) consumed by
      the per-cycle empty-model regression test.
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
}
(** Snapshot of the daemon's externally-visible runtime
    state.  Constructed by {!runtime_status_at} under
    [with_lock] so every field is consistent with one
    observation of the underlying {!state}. *)

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
    them for the same reason — every other reader goes
    through {!runtime_status} / {!fresh_judgments_json}. *)

(** {1 Response-model classification} *)

type governance_model_source =
  | Response_model
  | Telemetry_resolved
  | Unknown_sentinel
(** Source of the model id used for a governance
    judgment.  Used by the per-cycle empty-model metric
    to attribute classifications to fall-through paths. *)

val governance_model_source_to_string :
  governance_model_source -> string
(** [Response_model] → ["response_model"];
    [Telemetry_resolved] → ["telemetry_resolved"];
    [Unknown_sentinel] → ["unknown_sentinel"]. *)

val resolve_governance_model_used :
  raw_model:string ->
  canonical_model_id:string option ->
  string * governance_model_source
(** Picks the model id to pin against a judgment.
    [raw_model] (trimmed non-empty) wins; otherwise
    falls back to [canonical_model_id], otherwise the
    [unknown_provider] sentinel.  Returned tag is the
    classification that fired. *)

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
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.t) ->
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
  dispatch:(name:string -> args:Yojson.Safe.t -> Tool_result.t) ->
  build_facts:(unit -> Yojson.Safe.t) ->
  unit ->
  unit
(** Starts the periodic refresh fiber.  Idempotent — a
    second call against the same [base_path] returns
    without forking a new daemon.  No-op when the
    [governance_judge_enabled] config gate is off. *)
