(** Startup and drift helpers for {!Keeper_supervisor}. *)

val backoff_delay : int -> float

val keep_last_n : int -> 'a -> 'a list -> 'a list

val committed_tools_of_ambiguous_blocker : string -> string list

val persona_name_for_drift_check :
  Keeper_meta_contract.keeper_meta ->
  (string, Keeper_types_profile.keeper_toml_load_error) result

val persona_profile_path_for_drift_check :
  base_path:string -> string -> string

val log_persona_drift_if_missing :
  base_path:string -> Keeper_meta_contract.keeper_meta -> unit
