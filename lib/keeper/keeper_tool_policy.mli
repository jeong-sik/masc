(** Keeper_tool_policy — tool access control, presets, and allowed-tool resolution.

    Preset definitions are loaded from [config/tool_policy.toml] at startup
    via {!Keeper_tool_policy_config}.  Consumes {!Keeper_tool_registry} for
    candidate aggregation and core tools.

    @since v2.200.0 *)

open Keeper_types

module StringSet : Set.S with type elt = string

(** {1 Policy Initialization} *)

(** Load tool policy configuration from [config/tool_policy.toml].
    Must be called once at server startup before any preset resolution. *)
val init_policy_config :
  base_path:string -> (unit, string) result

(** Return the loaded policy config, if any.  Used for validation. *)
val policy_config_for_validation :
  unit -> Keeper_tool_policy_config.t option

(** Reset the loaded policy config and one-shot unloaded-accessor warning
    state. Intended for isolated regression tests only. *)
val reset_policy_config_for_test : unit -> unit

(** {1 Preset Names and Mapping} *)

(** Convert a [tool_preset] variant to its string name. *)
val preset_name_of_tool_preset : tool_preset -> string

(** Return configured preset names (excluding "full") for schema enum generation. *)
val configured_preset_names : unit -> string list

(** Check if [agent_preset] subsumes [required_preset] per the config hierarchy. *)
val preset_can_satisfy :
  agent_preset:string -> required_preset:string -> bool

(** {1 Workflow and Shell Permissions} *)

val allows_workflow_for_preset : tool_preset -> bool
val allows_shell_write_for_preset : tool_preset -> bool

(** {1 Git Clone Config} *)

val git_clone_allowed_orgs : unit -> string list option
(** [None] if policy config has not been loaded; [Some []] if loaded
    with an explicitly empty allowlist (any GitHub org is permitted);
    [Some orgs] if specific orgs are configured. *)
val git_clone_denied_repos : unit -> string list option
(** [None] if policy config has not been loaded; [Some repos] otherwise
    (empty list means no repos are denied). *)

(** Numeric tool-policy accessors require [init_policy_config] to have
    loaded [config/tool_policy.toml]. They raise [Invalid_argument] when
    queried before policy initialization instead of silently using
    permissive runtime defaults. Missing TOML keys still use the parser
    defaults in {!Keeper_tool_policy_config} after the config is loaded. *)
val clone_depth : unit -> int
val clone_timeout_sec : unit -> float
val push_timeout_sec : unit -> float
val pr_create_timeout_sec : unit -> float

(** {1 GH Cache Config} *)

(** These accessors follow the same loaded-policy requirement as the
    numeric git/gh timeout accessors above. *)
val gh_cache_ttl_sec : unit -> float
val gh_cache_fetch_page_size : unit -> int
val gh_cache_fetch_timeout_sec : unit -> float
val gh_cache_max_alternatives : unit -> int
val gh_cache_max_output_bytes : unit -> int

(** {1 MASC Schema Injection} *)

(** Inline MCP-runtime tools that are safe for keepers without an MCP session
    context. Shared by keeper policy and MCP protocol context metadata. *)
val keeper_safe_inline_tools : string list

val is_keeper_safe_inline_tool : string -> bool

(** Filter and inject MASC schemas for keeper tool selection.
    Call once after MASC schemas are registered. *)
val inject_masc_schemas : Masc_domain.tool_schema list -> unit

(** Filter raw schemas down to the masc_* subset a keeper can actually see. *)
val keeper_supported_masc_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list

(** Return names from [keeper_supported_masc_schemas]. *)
val keeper_supported_masc_tool_names_from_schemas :
  Masc_domain.tool_schema list -> string list

(** Filter names to only those present in the injected MASC set. *)
val select_existing_masc_tool_names : string list -> string list

(** {1 Tool Access Lookup}

    Per-tool access checks using immutable StringSet. *)

type tool_access_lookup = {
  candidate_names : string list;
  candidate_set : StringSet.t;
  allow_set : StringSet.t;
  deny_set : StringSet.t;
}

(** Build a StringSet from a list of tool names. *)
val tool_name_set : string list -> StringSet.t

(** Build a lookup structure from keeper metadata. *)
val tool_access_lookup_of_meta : keeper_meta -> tool_access_lookup

(** Check if a tool passes candidate + policy + deny filters. *)
val filter_by_access : lookup:tool_access_lookup -> string -> bool

(** Check candidate membership minus denied, ignoring policy.
    Used as execution gate for BM25-discovered tools. *)
val filter_by_universe : lookup:tool_access_lookup -> string -> bool

(** Execution gate: core tools bypass policy, others require allowlist.
    Rejects hallucinated tool names not in candidate_set. *)
val can_execute : lookup:tool_access_lookup -> string -> bool

(** {1 Tool Name Queries} *)

(** Policy-filtered MASC tool names for a keeper. *)
val keeper_masc_tool_names : keeper_meta -> string list

(** Policy-filtered MASC tool schemas for a keeper. *)
val keeper_masc_tool_schemas : keeper_meta -> Masc_domain.tool_schema list

(** Universe (policy-independent) MASC tool schemas for BM25 indexing. *)
val keeper_universe_masc_tool_schemas : keeper_meta -> Masc_domain.tool_schema list

(** Default model tools (keeper_model_tools + voice + tool_search). *)
val keeper_default_model_tools : keeper_meta -> Masc_domain.tool_schema list

(** {1 E6: .masc/ Write Protection} *)

(** Check if a path is in the keeper-writable whitelist.
    The path is lexically normalised (collapsing [.] and [..] segments)
    before prefix matching, preventing traversal bypasses like
    [.masc/playground/../reputation/].
    Returns [false] for paths outside the whitelist (e.g. reputation, economy).
    Whitelist: [.masc/playground/], [.masc/decision_audit/], [.worktrees/]. *)
val is_masc_write_allowed : string -> bool

(** Recovery minimum tool names: non-removable shards UNION essential MASC tools.
    Guaranteed non-empty (TLA+ ToolSetNeverEmpty).
    Phase B2: used in Failing phase as recovery floor.

    Two layers:
    - Shard floor: [removable=false] shards (currently [base] = local core).
    - Essential MASC: coordination + web lookup so a Failing keeper can
      check coordination state, look up information for recovery, and
      defer to operator approval. Mirrors [masc.essential] in
      [config/tool_policy.toml]. Sync regression in
      [test_failing_minimum_essential]. *)
val failing_minimum_tool_names : unit -> string list

(** Essential MASC tool names included in Failing recovery floor.
    SSOT: [config/tool_policy.toml] [masc.essential]. Exposed for
    sync regression test. *)
val essential_masc_minimum_names : string list

(** Policy-filtered allowed tool names.
    Returns empty list when [write_done] is true.
    When [phase] is [Failing] and decision layer level >= 2,
    returns [failing_minimum_tool_names] instead (recovery floor). *)
val keeper_allowed_tool_names :
  ?write_done:bool ->
  ?phase:Keeper_state_machine.phase ->
  keeper_meta -> string list

(** Universe tool names: candidates minus denied, no policy filter. *)
val keeper_universe_tool_names : keeper_meta -> string list

(** Preset-scoped universe: preset allowlist + core_always - denied. *)
val keeper_preset_universe_tool_names : keeper_meta -> string list

(** Tools safe to call on the keeper's last turn. *)
val last_turn_safe_tool_names : unit -> string list

(** {1 Tool Schema Assembly} *)

(** Policy-filtered model tool schemas. *)
val keeper_allowed_model_tools :
  ?write_done:bool -> keeper_meta -> Masc_domain.tool_schema list

(** Universe model tool schemas for Agent.run(). *)
val keeper_universe_model_tools : keeper_meta -> Masc_domain.tool_schema list

(** Preset-scoped universe model tool schemas for BM25 indexing. *)
val keeper_preset_universe_model_tools : keeper_meta -> Masc_domain.tool_schema list

(** Filter schemas by a set of allowed names.  O(1) per schema. *)
val filter_schemas_by_names :
  string list -> Masc_domain.tool_schema list -> Masc_domain.tool_schema list

(** Deduplicate tool schemas by name. *)
val dedupe_tool_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list

(** {1 Tool Description Lookup} *)

(** Lookup tool hint (first sentence + enum/required hints) by name.
    Returns [None] for unknown tools. *)
val tool_hint_of : string -> string option

(** Check if a tool name is in the keeper denied set. *)
val is_keeper_denied : string -> bool

(** Check if a tool requires MCP context injection. *)
val is_keeper_mcp_context_required : string -> bool
