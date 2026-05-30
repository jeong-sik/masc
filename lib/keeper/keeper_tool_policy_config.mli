(** Keeper_tool_policy_config — load tool policy from config/tool_policy.toml.

    Groups define named tool lists used for the keeper candidate set and
    policy group resolution.

    @since 2.236.0 *)

(** A parsed tool policy configuration. *)
type t

(** Load and parse [tool_policy.toml] from the resolved config root for
    [base_path] (honoring [MASC_CONFIG_DIR] when present).
    Returns [Error msg] if the file is missing or malformed. *)
val load : base_path:string -> (t, string) result

(** Resolve all groups and merge their tool names.
    Used to build the full candidate set. *)
val all_group_tools : t -> string list

(** Merge all MASC tool group names (unfiltered). *)
val all_masc_tools : t -> string list

(** List all defined group names. *)
val group_names : t -> string list

val resolve_group : t -> string -> string list option
