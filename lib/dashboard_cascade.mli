(** Dashboard projection for cascade configuration and runtime health.

    Exposes the current cascade.json profiles (raw JSON, parsed with weights)
    alongside the live {!Cascade_health_tracker.global} snapshot
    so operators can see *why* a given provider is preferred without
    re-running a turn.

    Contracts:
    - {!config_json} reads {!Cascade_runtime.cascade_config_path} through the
      existing mtime-cached loader. No mutation, no network.
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

    @since 0.6.0 *)
val config_json : unit -> Yojson.Safe.t

(** JSON snapshot of the cascade health tracker.

    Shape:
    {[
      {
        "updated_at": "2026-04-15T08:15:00Z",
        "window_sec": 300.0,
        "cooldown_threshold": 3,
        "cooldown_sec": 60.0,
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
