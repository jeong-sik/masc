(** Keeper_tool_policy_config — load tool policy from config/tool_policy.toml.

    Replaces hardcoded preset definitions with declarative configuration.
    Groups define named tool lists; presets compose groups.

    @since 2.236.0 *)

(** A parsed tool policy configuration. *)
type t

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
  string list option

(** List all defined preset names. *)
val preset_names : t -> string list

(** List all defined group names. *)
val group_names : t -> string list

(** Resolve a single group name to tool names.
    Returns [None] if the group is not defined. *)
val resolve_group : t -> string -> string list option
