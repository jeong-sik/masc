(** Tool_policy_failure_site — closed sum for the [site] label on
    [metric_keeper_tool_policy_failures] (2 sites across
    keeper_tool_policy.ml and tool_code_write.ml).

    Both sites surface failures of the tool-policy TOML load path. *)

type t =
  | Tool_code_write_load_failed
  (** tool_policy.toml load failed inside the tool_code_write path. *)
  | Policy_config_not_loaded (** Policy config absent or empty at preset lookup time. *)

val to_label : t -> string
