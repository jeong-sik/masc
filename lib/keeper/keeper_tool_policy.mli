(** Keeper_tool_policy — keeper tool surface and denylist resolution.

    Tool access is descriptor/registry driven with denylist filtering only.
    Policy group classification and config-driven groups have been removed.

    @since v2.200.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

module StringSet : Set.S with type elt = string

(** {1 MASC Schema Injection} *)

val is_keeper_safe_inline_tool : string -> bool

(** Filter and inject descriptor-backed MASC handler schemas.
    Dispatch-only routes are retained outside the model surface. A supported
    schema with no descriptor, duplicate descriptors, or any descriptor with a
    missing canonical schema is rejected and emitted as a structured error. *)
val inject_masc_schemas : Masc_domain.tool_schema list -> unit

(** Pure diagnostic projection used by startup validation and invariant tests. *)
val missing_canonical_schema_names :
  Keeper_tool_descriptor.t list -> string list

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
      defer to operator approval. Hardcoded in this module.
      Sync regression in [test_failing_minimum_essential]. *)
val failing_minimum_tool_names : unit -> string list

(** Essential MASC tool names included in Failing recovery floor.
    Hardcoded. Exposed for sync regression test. *)
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

(** Complete descriptor-projected Keeper model schema inventory before
    per-Keeper candidate and deny filtering. No shard or injected-schema
    fallback is admitted. *)
val all_keeper_model_tool_schemas : unit -> Masc_domain.tool_schema list

(** Descriptor-projected universe model schemas for Agent.run(). No shard or
    injected-schema fallback is admitted. *)
val keeper_universe_model_tools : keeper_meta -> Masc_domain.tool_schema list

(** Active descriptor-projected model tool schemas for BM25 indexing. *)
val keeper_model_tool_schemas : keeper_meta -> Masc_domain.tool_schema list

(** Filter schemas by a set of allowed names.  O(1) per schema. *)
val filter_schemas_by_names :
  string list -> Masc_domain.tool_schema list -> Masc_domain.tool_schema list

(** Deduplicate tool schemas by name. *)
val dedupe_tool_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list

(** {1 Tool Description Lookup} *)

(** Lookup a descriptor-projected tool hint by model name.
    Returns [None] for unknown tools. *)
val tool_hint_of : string -> string option

(** Check if a tool requires MCP context injection. *)
val is_keeper_mcp_context_required : string -> bool
