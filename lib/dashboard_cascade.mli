
(** Dashboard projection for cascade configuration and runtime health.

    Exposes the validated runtime cascade catalog alongside the live
    {!Cascade_health_tracker.global} snapshot so operators can see *why*
    a given provider is preferred without re-running a turn.

    Contracts:
    - {!config_json} reads the validated runtime snapshot from
      {!Cascade_catalog_runtime}; rejected hot reloads do not change the
      advertised profile set.
    - {!health_json} reads the global health tracker singleton.
    - Both return JSON suitable for dashboard consumption; callers are
      expected to forward via an HTTP handler without further massaging.

    @since 0.6.0 *)

(** JSON bundle describing the current cascade configuration.

    Shape:
    {[
      {
        "updated_at": "2026-04-15T08:15:00Z",
        "config_path": "/path/to/cascade.json" | null,
        "source_kind": "json" | "toml",
        "source_path": "/path/to/cascade.json" | "/path/to/cascade.toml",
        "profiles": [
          { "name": "keeper_unified",
            "keeper_assignable": true,
            "candidates": [ { "model": "glm-coding:glm-5.1",
                              "config_weight": 50,
                              "effective_weight": 50,
                              "success_rate": 1.0,
                              "in_cooldown": false } , ... ],
            "source": "named" },
          ...
        ],
        "keeper_profiles": [ { "keeper": "sangsu",
                               "cascade_name": "keeper_unified" }, ... ]
      }
    ]}

    Only validated profiles from the active runtime snapshot are surfaced in
    [profiles]. Each profile also carries [keeper_assignable] metadata from the
    live [cascade.json] catalog so the UI can distinguish keeper-routing
    profiles from manual/system-only trial profiles. Keepers whose raw
    [cascade_name] drifts from the validated catalog still appear in
    [keeper_profiles] so the UI can show the mismatch.

    @since 0.6.0 *)
val config_json : unit -> Yojson.Safe.t

(** Raw [cascade.json] payload from the active resolved config root.

    Shape:
    {[
      {
        "updated_at": "2026-04-21T08:15:00Z",
        "config_path": "/path/to/cascade.json" | null,
        "source_kind": "json" | "toml",
        "source_path": "/path/to/cascade.json" | "/path/to/cascade.toml",
        "source_editable": true,
        "source_text": "{ ... }\n" | "comment = ...\n[profile]\n...",
        "raw_json_editable": true | false,
        "raw_json": "{ ... }\n"
      }
    ]}

    [source_text] is the editable active source file content. In JSON mode it
    matches [raw_json]; in TOML mode it is the live [cascade.toml] source while
    [raw_json] remains the generated runtime [cascade.json] preview.

    [config_path] is the resolver's candidate [cascade.json] path under the
    active config root, even when the file does not exist yet. In that missing
    JSON-file case, both [source_text] and [raw_json] default to ["{}\n"] so
    operators can bootstrap a config from the dashboard editor. When
    [source_kind] is ["toml"], [raw_json_editable] stays [false] because the
    preview is generated, but [source_editable] remains [true].

    @since 0.160.1 *)
val raw_config_json : unit -> Yojson.Safe.t

(** Validate and persist the active cascade authoring source, then return the
    refreshed {!config_json} snapshot.

    In JSON mode, the input must be syntactically valid JSON and is written to
    the active [cascade.json]. In TOML mode, the input must be syntactically
    valid TOML and is written to the active [cascade.toml], after which the
    generated runtime [cascade.json] is materialized from that source.

    Semantic validation is not a hard gate here: invalid cascades are still
    written and surfaced through the returned validation metadata so the
    runtime can continue serving the last known good snapshot. Missing parent
    directories are created on demand under the active config root.

    @since 0.160.1 *)
val save_raw_config_json :
  string -> (Yojson.Safe.t, string) Result.t

(** Build the per-keeper row of [keeper_profiles] without a full
    {!Keeper_registry.registry_entry}. Exposed so the raw-vs-canonical
    contract can be exercised in tests directly.

    The [cascade_name] argument is forwarded as-is (not canonicalized);
    the [canonical] field is [Keeper_cascade_profile.resolve_live
    cascade_name]. When the two match, the UI renders "—" in the
    canonical column.

    @since 0.9.9 *)
val keeper_profile_fields :
  keeper:string -> cascade_name:string -> (string * Yojson.Safe.t) list

(** JSON snapshot of the cascade health tracker, merged with
    [cascade.json]'s declared candidate list.

    Entries come from two sources:
    1. {!Cascade_health_tracker.all_providers Health.global} — every
       provider the tracker has observed events for.
    2. Providers declared in any [cascade.json] profile but absent from
       the tracker, synthesised via {!zero_provider_info}.  Lets the UI
       surface "why isn't this provider being used?" for candidates that
       never get selected.

    Shape:
    {[
      {
        "updated_at": "2026-04-15T08:15:00Z",
        "window_sec": 300.0,
        "cooldown_threshold": 3,
        "cooldown_sec": 30.0,
        "hard_quota_cooldown_sec": 3600.0,
        "providers": [
          { "provider_key": "glm-coding",
            "success_rate": 0.87,
            "consecutive_failures": 0,
            "in_cooldown": false,
            "cooldown_expires_at": null,
            "events_in_window": 42,
            "trust_score": 0.87,
            "health_score": 87,
            "rejected_in_window": 0,
            "declared": true,
            "status": "active" },
          { "provider_key": "kimi_cli",
            "success_rate": 1.0,
            "consecutive_failures": 0,
            "in_cooldown": false,
            "cooldown_expires_at": null,
            "events_in_window": 0,
            "trust_score": 1.0,
            "health_score": 100,
            "rejected_in_window": 0,
            "declared": true,
            "status": "configured" },
          ...
        ]
      }
    ]}

    [status] is one of [active | cooldown | configured]; see
    {!provider_status}.  [declared] is [true] iff [cascade.json] lists a
    model whose scheme prefix matches [provider_key].

    When [?base_path] is supplied, each provider entry additionally
    carries performance aggregates from the last [?window_minutes]
    (default [30]) of keeper decisions.jsonl — [avg_prompt_tok_per_sec],
    [avg_decode_tok_per_sec], [avg_tok_per_sec], [avg_latency_ms],
    [p50_latency_ms], [p95_latency_ms], [request_count].  When omitted,
    those fields are [null] and no jsonl scan happens; the response
    also carries [perf_window_minutes: null].  Perf aggregator failures
    fall back to [null] entries and log at [warn] level — a corrupt
    jsonl must not take this endpoint offline.

    @since 0.6.0
    @since 0.173.0 [declared] and [status] fields added; providers list
                   now merges declared-but-untracked candidates.
    @since 0.173.1 [?base_path] + [?window_minutes] added; per-provider
                   perf fields are now part of the shape.
    @since 0.184.0 [trust_score] and [health_score] fields added. *)
val health_json :
  ?window_minutes:int ->
  ?base_path:string ->
  unit -> Yojson.Safe.t

(** Classify a provider's operational state from tracker fields.  See
    the [status] enum in {!health_json}. *)
val provider_status : Cascade_health_tracker.provider_info -> string

(** Synthesise a provider_info with optimistic defaults for a provider
    that is declared in [cascade.json] but has no tracker events in the
    current window.  Used by {!health_json} to merge declared-only
    candidates; exposed for tests so fixtures don't have to hand-build
    the record. *)
val zero_provider_info : string -> Cascade_health_tracker.provider_info

(** Serialize a tracker entry (or synthesized placeholder) to the shape
    described by {!health_json}.  [declared] controls the [declared]
    field; [status] is derived via {!provider_status}.  [?perf], when
    supplied, populates the seven perf fields (avg_*_tok_per_sec,
    *_latency_ms, request_count) from
    {!Model_inference_metrics.provider_rollup}; otherwise those fields
    are [null].  [trust_score] is derived from
    {!Cascade_trust.trust_score}; [health_score] is the rounded
    percentage form used by the dashboard. *)
val provider_entry_to_json :
  declared:bool ->
  ?perf:Model_inference_metrics.provider_stats ->
  Cascade_health_tracker.provider_info ->
  Yojson.Safe.t

(** {1 Phase 2a operator recommendations}

    Observation-only nudges based on [trust_score] from Phase 1.  The
    classifier never writes config — it only surfaces actionable hints
    in the dashboard JSON.  Phase 2b is what makes these self-applying.

    @since 0.176.0 *)

(** Recommended operator action for a low-trust provider. *)
type recommendation_action =
  | Reduce_weight
      (** Trust ∈ [0.1, 0.3): partially working but unreliable.
          Suggested response: halve the cascade.toml weight. *)
  | Disable
      (** Trust < 0.1 with no stuck-fingerprint streak: provider has
          decayed across multiple persistent failures. *)
  | Investigate
      (** Stuck on the same fingerprint ≥ 5 times, OR trust < 0.1 with
          high-volume failures: likely a config / auth issue, not a
          provider quality problem.  Operator should inspect
          [cascade_audit] before reducing weight. *)

val recommendation_action_to_string : recommendation_action -> string

type recommendation = {
  rec_provider_key : string;
  rec_trust_score : float;
  rec_same_fingerprint_count : int;
  rec_events_in_window : int;
  rec_top_fingerprint : string option;
  rec_action : recommendation_action;
  rec_rationale : string;
}

val classify_recommendation :
  Cascade_health_tracker.provider_info -> recommendation option
(** Classify a single provider snapshot.  Returns [None] for healthy
    providers (no operator action recommended). *)

val low_trust_recommendations :
  Cascade_health_tracker.provider_info list -> recommendation list
(** Apply {!classify_recommendation} to each provider, drop the
    healthy ones, and sort ascending by [trust_score] so the most
    urgent items render first. *)

val recommendation_to_json : recommendation -> Yojson.Safe.t

val recommendations_json : unit -> Yojson.Safe.t
(** Standalone endpoint — reads {!Cascade_health_tracker.global},
    runs {!low_trust_recommendations}, returns a JSON array.
    Also embedded under ["recommendations"] in {!health_json}. *)

(** [provider_scheme_of_model_string s] returns the scheme prefix of a
    [cascade.json] model spec (the text before the first [:]), or [s]
    unchanged when no [:] is present.  The scheme corresponds to the
    [provider_key] produced at runtime by
    [Keeper_hooks_oas.provider_of_model] for prefixed specs. *)
val provider_scheme_of_model_string : string -> string

(** [declared_provider_schemes_of_config ?config_path ()] returns the
    sorted, de-duplicated list of provider scheme prefixes declared by
    any cascade profile in [config_path].

    Returns the empty list when the path is [None] or the catalog
    cannot be loaded — a failure here must not take the health
    endpoint offline.  Used by {!health_json} to augment the tracker's
    provider list with zero-traffic candidates. *)
val declared_provider_schemes_of_config :
  ?config_path:string -> unit -> string list

(** JSON snapshot of the {!Cascade_client_capacity} registry —
    the per-URL/sentinel slot table used for ollama HTTP and CLI
    subprocess throttling.

    Shape:
    {[
      {
        "updated_at": "2026-04-16T22:30:00Z",
        "entries": [
          { "key": "cli:claude_code",
            "kind": "cli",
            "total": 1,
            "active": 0,
            "available": 1 },
          { "key": "http://127.0.0.1:11434",
            "kind": "ollama",
            "total": 1,
            "active": 1,
            "available": 0 },
          ...
        ]
      }
    ]}

    Entries are sorted by [(kind, key)] for stable rendering.
    The [kind] field is the dashboard's classification:
    [cli] for [cli:*] sentinels, [ollama] for keys containing
    [:11434], [other] for any manually-registered slot.

    @since 0.9.9 *)
val client_capacity_json : unit -> Yojson.Safe.t

(** JSON snapshot of the {!Cascade_client_capacity_history} ring
    buffer — per-event transitions (acquire / release / slot-full
    rejection) recorded by the client-capacity semaphore.

    Complements {!client_capacity_json}: that one answers "how full
    is the slot right now?", this one answers "how often did
    saturation happen in the last hour?" without a separate metrics
    pipeline.

    Shape:
    {[
      {
        "updated_at": "2026-04-16T22:31:00Z",
        "total_events": 3,
        "events": [
          { "ts": 1713280000.5,
            "key": "cli:claude_code",
            "kind": "acquired",
            "active_after": 1 },
          { "ts": 1713280001.2,
            "key": "cli:claude_code",
            "kind": "rejected_full",
            "active_after": 1 },
          ...
        ]
      }
    ]}

    Events are returned newest-first (the ring buffer is walked from
    write-head backwards).  [kind] strings are ["acquired"],
    ["released"], ["rejected_full"].

    @param limit   max events returned (default 100).
    @param kind    dashboard classification filter: one of
           ["cli"], ["ollama"], ["other"].  Unknown filters return
           an empty event list; omitting returns every kind.
    @param since_ts  keep only events with [ts >= since_ts].

    @since 0.9.9 *)
val client_capacity_history_json :
  ?limit:int ->
  ?kind:string ->
  ?since_ts:float ->
  unit -> Yojson.Safe.t

(** JSON projection of {!Cascade_strategy_trace} — recent per-cycle
    strategy decisions (candidate in/out counts, backoff, kind).

    Shape:
    {[
      {
        "updated_at": "ISO-8601",
        "total_events": <int>,
        "events": [
          { "ts": <unix seconds>,
            "cascade_name": "keeper_unified",
            "strategy": "circuit_breaker_cycling",
            "cycle": 2,
            "candidates_in": 3,
            "candidates_out": 1,
            "backoff_ms": 2000,
            "kind": "ordered" | "filtered_empty" | "exhausted" }, ...
        ]
      }
    ]}

    Sorted newest-first (delegated to {!Cascade_strategy_trace.snapshot}).

    @param limit    max events returned (default 100).
    @param cascade  filter by [cascade_name]; omit to include every cascade.

    @since 0.9.10 *)
val strategy_trace_json :
  ?limit:int ->
  ?cascade:string ->
  unit -> Yojson.Safe.t

(** Instantaneous SLO snapshot computed from the live
    {!Cascade_strategy_trace} ring buffer.

    Mirrors the SLO definitions codified in
    {{:../../infrastructure/monitoring/cascade-slo.yml}cascade-slo.yml}
    but evaluated in-process so the MASC dashboard can surface the
    same targets without a Prometheus round-trip.

    Shape:
    {[
      {
        "updated_at": "ISO-8601",
        "window_sample_size": 1000,
        "targets": {
          "ordered_ratio_min":    0.99,
          "exhaustion_count_max": 10,
          "burn_rate_max":        1.0
        },
        "current": {
          "ordered_ratio":     0.987,
          "exhaustion_count":  3,
          "burn_rate":         1.3,
          "total_events":      847
        },
        "status":        "ok" | "warn" | "violated",
        "violations":    ["ordered_ratio", "burn_rate", ...]
      }
    ]}

    Semantics:
    - [ordered_ratio] is computed over the most recent {b up to 1000}
      events (defensive cap matching the default ring limit).  When
      the ring is empty the ratio defaults to [1.0] (treat idle as
      healthy).
    - [exhaustion_count] counts [Exhausted] events in the same sample.
    - [burn_rate] is [(1 - ordered_ratio) / 0.01], matching the
      Prometheus recording rule [masc:cascade_error_budget_burn].
    - [status] derives from [violations]: empty → ["ok"], burn_rate
      alone → ["warn"], any SLO hard-breach → ["violated"].

    @since 0.9.11 *)
val slo_json : unit -> Yojson.Safe.t
