(** Dashboard projection for cascade configuration and runtime health.

    Exposes the current cascade.json profiles (raw JSON, parsed with weights)
    alongside the live {!Cascade_health_tracker.global} snapshot
    so operators can see *why* a given provider is preferred without
    re-running a turn.

    Contracts:
    - {!config_json} reads {!Oas_worker.default_config_path} through the
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
