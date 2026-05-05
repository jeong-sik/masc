(** Keeper_tool_registry — runtime tool name sources and schema injection.

    Static tool name lists have been moved to config/tool_policy.toml.
    This module retains only runtime-resolved names (Tool_catalog,
    Tool_shard, injected MASC tools), core always-visible tools,
    and dynamic schema injection.

    See [Keeper_tool_policy_config] for the declarative tool groups
    and presets. *)

(** Trim, drop empty entries, and dedupe a list preserving order. *)
val dedupe_tool_names : string list -> string list

(** Tool names returned by [Tool_catalog] for the [Keeper_internal]
    surface — the candidate pool consumed by tool_search. *)
val keeper_internal_candidate_tool_names : string list

(** Tool schemas declared by the [voice] shard, or [[]] when the
    shard is not registered. *)
val keeper_voice_tool_schemas : Masc_domain.tool_schema list

(** Tools that bypass policy restrictions: extend_turns,
    keeper_context_status, keeper_stay_silent, keeper_tool_search. *)
val core_always_tools : string list

(** Core tools always visible to the LLM — superset of
    [core_always_tools] used as the discovery pool. *)
val core_discovery_tools : string list

val effective_core_tools : unit -> string list

(** Keeper tools the dispatcher accepts but withholds from the
    visible/core set; served only when a keeper opts in via
    policy_config.also_allow. Exported so [Tool_registration_check]
    does not flag them as orphan toml entries (#7696). *)
val keeper_admin_dispatched_tools : string list

(** Lookup hashtable for [core_always_tools]. *)
val core_always_set : (string, unit) Hashtbl.t

val is_core_always_tool : string -> bool

(** Read-only tools that live outside any [Tool_shard]
    (e.g. [keeper_tool_search]). *)
val non_shard_read_only_tools : string list

(** All read-only keeper tools — shard read-only tools plus
    [non_shard_read_only_tools], sorted/deduped. *)
val keeper_read_only_tools : string list

val keeper_read_only_set : (string, unit) Hashtbl.t

val is_keeper_read_only_tool : string -> bool

(** Combined read-only check: keeper-local set + Tool_dispatch
    read-only/idempotent classification. *)
val is_effectively_read_only_tool : string -> bool

(** Negation of [is_effectively_read_only_tool]. *)
val has_mutating_side_effect : string -> bool

(** Read-only [gh] subcommand prefixes used by the input-aware
    keeper_shell op=gh classifier. *)
val gh_read_only_prefixes : string list

(** Returns [true] when a [gh api ...] invocation is effectively a
    GET request (no -X/--method, no -f/-F/--field, not graphql).
    [cmd_lower] must already be lowercased and trimmed. *)
val is_gh_api_read_only : string -> bool

(** Strip leading [gh] tokens and re-join with single spaces. *)
val normalize_gh_command : string -> string

(** Project a [keeper_shell op=gh] input JSON to its normalized
    [cmd] string ([""] when missing). *)
val gh_effective_cmd : Yojson.Safe.t -> string

(** [true] iff [input] has [op = "gh"]. *)
val is_shell_gh_op : Yojson.Safe.t -> bool

(** Read-only [git] action names used by [Masc Code_git] input
    classification. *)
val git_read_only_actions : string list

(** Project a [Masc Code_git] input JSON to its [action] field
    lowercased ([""] when missing). *)
val git_action_of_input : Yojson.Safe.t -> string

(** Input-aware read-only check: [keeper_shell op=gh] and
    [masc_code_git] mix read-only and mutating subcommands within
    one tool name; the input JSON disambiguates. *)
val is_read_only_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Whether the tool, given its input, is exempt from the per-turn
    main-worktree boundary block. *)
val is_main_worktree_boundary_exempt_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Tools whose mutations are safe to leave un-reconciled after
    a transient failure (board posts, broadcasts, task_done). *)
val reconcile_safe_tools : string list

val reconcile_safe_set : (string, unit) Hashtbl.t

val is_reconcile_safe_tool : string -> bool

(** [true] iff [names] is non-empty and every name is in
    [reconcile_safe_set]. *)
val all_tools_reconcile_safe : string list -> bool

(** Mutable ref holding injected MASC tool schemas; populated at
    boot by the dashboard / tool_registration paths. *)
val masc_schemas_ref : Masc_domain.tool_schema list ref

(** Names extracted from [!masc_schemas_ref] in declaration order. *)
val injected_masc_tool_names : unit -> string list

(** SSOT schema for [keeper_tool_search]. Defined here because this
    module is the canonical owner of keeper-internal tool metadata.
    Consumed by [Keeper_tool_policy.keeper_default_model_tools]. *)
val keeper_tool_search_schema : Masc_domain.tool_schema
