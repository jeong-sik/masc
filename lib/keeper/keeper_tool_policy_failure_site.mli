(** Keeper_tool_policy_failure_site — closed sum for the [site] label on
    [metric_keeper_tool_policy_failures].

    Both sites surface failures of the tool-policy TOML load path. *)

type t =
  | Github_clone_policy_load_failed
  (** tool_policy.toml load failed inside keeper GitHub clone validation. *)
  | Policy_config_not_loaded (** Policy config absent or empty at preset lookup time. *)

val to_label : t -> string
