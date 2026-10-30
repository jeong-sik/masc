(** The configured Keeper periodic interval, read from the execution setting.
    This is a policy value, not a measured turn interval: explicit work can
    arrive earlier and a running turn can complete later. *)

type tempo_state = { current_interval_s : float }

val get_tempo : Workspace_utils.config -> tempo_state
