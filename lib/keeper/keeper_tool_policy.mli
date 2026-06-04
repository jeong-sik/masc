(** Keeper_tool_policy — keeper tool surface and denylist resolution.

    Group definitions are loaded from [config/tool_policy.toml] at startup
    via {!Keeper_tool_policy_config} for legacy/recovery surfaces. Runtime
    execution is descriptor/registry driven and filtered by denylist.

    @since v2.200.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringSet : Set.S with type elt = string

(** {1 Policy Initialization} *)

(** Load tool policy configuration from [config/tool_policy.toml].
    Must be called once at server startup before legacy/recovery surface
    resolution. *)
val init_policy_config :
  base_path:string -> (unit, string) result

(** Return the loaded policy config, if any.  Used for validation. *)
val policy_config_for_validation :
  unit -> Keeper_tool_policy_config.t option

(** Reset the loaded policy config and one-shot unloaded-accessor warning
    state. Intended for isolated regression tests only. *)
val reset_policy_config_for_test : unit -> unit

(** {1 MASC Schema Injection} *)

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


(** {1 Tool Surface Lookup}

    Per-tool candidate/deny checks using immutable StringSet. *)

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

(** Candidate reachability: registered candidate and not denied.
    Per-keeper tool_access/allow does not gate execution — only the denylist
    bites. Used as the execution gate for BM25-discovered tools. *)
val filter_by_universe : lookup:tool_access_lookup -> string -> bool

(** Execution gate: core tools bypass candidate_set; other tools must be
    registered candidates and not denied.
    Rejects hallucinated tool names not in candidate_set. *)
val can_execute : lookup:tool_access_lookup -> string -> bool

(** {1 Tool Name Queries} *)

(** Policy-filtered MASC tool names for a keeper. *)
val keeper_masc_tool_names : keeper_meta -> string list

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
    - Essential MASC: workspace + web lookup so a Failing keeper can
      check workspace state, look up information for recovery, and
      defer to operator approval. Mirrors [masc.essential] in
      [config/tool_policy.toml]. Sync regression in
      [test_failing_minimum_essential]. *)
val failing_minimum_tool_names : unit -> string list

(** Essential MASC tool names included in Failing recovery floor.
    SSOT: [config/tool_policy.toml] [masc.essential]. Exposed for
    sync regression test. *)
val essential_masc_minimum_names : string list

(** Active descriptor/registry tool names minus denied tools.
    Returns empty list when [write_done] is true.
    When [phase] is [Failing] and decision layer level >= 2,
    returns [failing_minimum_tool_names] instead (recovery floor). *)
val keeper_allowed_tool_names :
  ?write_done:bool ->
  ?phase:Keeper_state_machine.phase ->
  keeper_meta -> string list

(** Universe tool names: candidates minus denied, no policy filter. *)
val keeper_universe_tool_names : keeper_meta -> string list

(** Tool search scope: active candidates + core_always - denied. *)
val keeper_tool_search_scope : keeper_meta -> string list

(** {1 Tool Schema Assembly} *)

(** Universe model tool schemas for Agent.run(). *)
val keeper_universe_model_tools : keeper_meta -> Masc_domain.tool_schema list

(** Active descriptor/registry model tool schemas for BM25 indexing. *)
val keeper_model_tool_schemas : keeper_meta -> Masc_domain.tool_schema list

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

(** Check if a tool requires MCP context injection. *)
val is_keeper_mcp_context_required : string -> bool
