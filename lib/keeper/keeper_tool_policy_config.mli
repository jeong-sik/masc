(** Keeper_tool_policy_config — load tool policy from config/tool_policy.toml.

    Replaces hardcoded preset definitions with declarative configuration.
    Groups define named tool lists; presets compose groups.

    @since 2.236.0 *)

(** A parsed tool policy configuration. *)
type t

(** The result of resolving a preset: either the full candidate set
    (when [all_candidates = true] in config) or an explicit subset. *)
type preset_resolution =
  | All_candidates        (** Use the entire candidate tool set *)
  | Subset of string list (** Use exactly this list of tool names *)

(** Load and parse config/tool_policy.toml relative to [base_path].
    Returns [Error msg] if the file is missing or malformed. *)
val load : base_path:string -> (t, string) result

(** Resolve a preset name to its tool name list.
    Shard-backed groups are resolved via [Tool_shard] at call time.
    MASC tools are filtered through [masc_filter] if provided.
    Returns [None] if the preset is not defined.

    @param masc_filter  applied to each MASC tool name; only those
      returning [true] are included.  Defaults to [fun _ -> true]. *)
val resolve_preset :
  t ->
  string ->
  ?masc_filter:(string -> bool) ->
  unit ->
  preset_resolution option

(** Resolve all groups and merge their tool names.
    Used to build the full candidate set (superset of all presets). *)
val all_group_tools : t -> string list

(** Merge all MASC tool group names (unfiltered). *)
val all_masc_tools : t -> string list

(** List all defined preset names. *)
val preset_names : t -> string list

(** List all defined group names. *)
val group_names : t -> string list

(** Check if [agent_preset]'s tool set covers [required_preset]'s.
    Config-derived — no hardcoded hierarchy. *)
val preset_can_satisfy : t -> agent_preset:string -> required_preset:string -> bool

(** Check if a preset is allowed to execute workflow mutations
    (pr merge, pr close, etc.) as configured in [permissions.workflow_presets]. *)
val allows_workflow : t -> string -> bool

(** Check if a preset allows shell write operations
    as configured in [permissions.shell_write_presets]. *)
val allows_shell_write : t -> string -> bool

(** Git clone allowed GitHub org names from [git_clone.allowed_orgs]. *)
val git_clone_allowed_orgs : t -> string list

(** Repos blocked even if org is allowed, from [git_clone.denied_repos]. *)
val git_clone_denied_repos : t -> string list

(** Clone depth: 0 = full clone, N = shallow --depth N.
    From [git_clone.default_depth], default 0. *)
val clone_depth : t -> int

(** Timeout in seconds for git clone operations.
    From [git_clone.clone_timeout_sec], default 120.0. *)
val clone_timeout_sec : t -> float

(** Timeout in seconds for git push operations.
    From [git_clone.push_timeout_sec], default 60.0. *)
val push_timeout_sec : t -> float

(** Timeout in seconds for PR creation operations.
    From [git_clone.pr_create_timeout_sec], default 30.0. *)
val pr_create_timeout_sec : t -> float

val resolve_group : t -> string -> string list option
