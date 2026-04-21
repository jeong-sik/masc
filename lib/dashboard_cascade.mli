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
        "profiles": [
          { "name": "keeper_unified",
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
    [profiles]. Keepers whose raw [cascade_name] drifts from the validated
    catalog still appear in [keeper_profiles] so the UI can show the mismatch.

    @since 0.6.0 *)
val config_json : unit -> Yojson.Safe.t

(** Build the per-keeper row of [keeper_profiles] without a full
    {!Keeper_registry.registry_entry}. Exposed so the raw-vs-canonical
    contract can be exercised in tests directly.

    The [cascade_name] argument is forwarded as-is (not canonicalized);
    the [canonical] field is [Keeper_cascade_profile.canonicalize
    cascade_name]. When the two match, the UI renders "—" in the
    canonical column.

    @since 0.9.9 *)
val keeper_profile_fields :
  keeper:string -> cascade_name:string -> (string * Yojson.Safe.t) list

(** JSON snapshot of the cascade health tracker.

    Shape:
    {[
      {
        "updated_at": "2026-04-15T08:15:00Z",
        "window_sec": 300.0,
        "cooldown_threshold": 3,
        "cooldown_sec": 60.0,
        "hard_quota_cooldown_sec": 3600.0,
        "providers": [
          { "provider_key": "glm:glm-5.1",
            "success_rate": 0.87,
            "consecutive_failures": 0,
            "in_cooldown": false,
            "cooldown_expires_at": null,
            "events_in_window": 42 },
          ...
        ]
      }
    ]}

    @since 0.6.0 *)
val health_json : unit -> Yojson.Safe.t

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
