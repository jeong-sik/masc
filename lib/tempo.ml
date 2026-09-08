(** Keeper cadence published to operator surfaces. The execution loop and
    this projection read the same live runtime setting, including overrides. *)
type tempo_state = { current_interval_s : float }

let get_tempo (_config : Workspace_utils.config) : tempo_state =
  { current_interval_s =
      float_of_int (Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec) }
