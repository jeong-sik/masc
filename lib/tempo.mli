(** Tempo — the orchestrator polling interval published to operator surfaces.

    The value is [MASC_TEMPO_DEFAULT_INTERVAL_SEC], a setting rather than a
    measurement: nothing adjusts it at runtime, and it is not the interval the
    orchestrator runs at ([Env_config.Orchestrator.check_interval_seconds]). *)

type tempo_state = { current_interval_s : float }

val get_tempo : Workspace_utils.config -> tempo_state
