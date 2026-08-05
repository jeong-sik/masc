(** Tempo — the orchestrator polling interval published to operator surfaces.

    This was an adaptive controller: it read the backlog, mapped the priority
    mix to a fast/normal/slow interval, and persisted the choice to
    [.masc/tempo.json]. Nothing ever called the adjusting half, so the file was
    never written and every read returned the configured default. What the
    dashboards showed as a tempo was that constant.

    The constant is what remains. It is still published, so operator surfaces
    keep their field, and it is now visibly a setting rather than a
    measurement.

    The number is [MASC_TEMPO_DEFAULT_INTERVAL_SEC], which is not the interval
    the orchestrator actually runs at -- that is
    [Env_config.Orchestrator.check_interval_seconds]. Reconciling the two
    changes what operator surfaces report and is left to its own change. *)

type tempo_state = { current_interval_s : float }

let get_tempo (_config : Workspace_utils.config) : tempo_state =
  { current_interval_s = Env_config.Tempo.default_interval_seconds }
