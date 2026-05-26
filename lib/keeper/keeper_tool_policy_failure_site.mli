(** Keeper_tool_policy_failure_site — closed sum for the [site] label on
    [metric_keeper_tool_policy_failures].

    The site surfaces failures of the tool-policy TOML load path. *)

type t =
  | Policy_config_not_loaded (** Policy config absent or empty at preset lookup time. *)

val to_label : t -> string
