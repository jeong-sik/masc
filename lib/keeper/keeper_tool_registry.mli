(** Keeper_tool_registry — runtime tool name sources and schema injection.

    This module retains runtime-resolved names (Tool_catalog, Tool_shard,
    injected MASC tools), core always-available tools, and dynamic schema
    injection. Execution surfaces are resolved from descriptors/registries
    and then denylist-filtered. *)

(** Trim, drop empty entries, and dedupe a list preserving order. *)
val dedupe_tool_names : string list -> string list

(** Tool names returned by [Tool_catalog] for the [Keeper_internal]
    surface — the candidate pool consumed by tool_search. *)
val keeper_internal_candidate_tool_names : string list

(** Tool schemas declared by the [voice] shard, or [[]] when the
    shard is not registered. *)
val keeper_voice_tool_schemas : Masc_domain.tool_schema list

(** Tools that bypass policy restrictions:
    keeper_context_status and keeper_tool_search. *)
val core_always_tools : string list

(** Core tools always visible to the LLM — superset of
    [core_always_tools] used as the discovery pool. *)
val core_discovery_tools : string list

val effective_core_tools : unit -> string list

(** Lookup hashtable for [core_always_tools]. *)
val core_always_set : (string, unit) Hashtbl.t

val is_core_always_tool : string -> bool

(** Descriptor-projected read-only tools. *)
val descriptor_read_only_tools : string list

(** All read-only keeper tools — shard read-only tools plus descriptor
    projections, sorted/deduped. *)
val keeper_read_only_tools : string list

val is_keeper_read_only_tool : string -> bool

(** Combined read-only check: keeper-local lookup + catalog-backed
    read-only/idempotent classification. *)
val is_effectively_read_only_tool : string -> bool

(** Strict non-mutating read-only check. Unlike
    [is_effectively_read_only_tool], this excludes idempotent-but-mutating
    tools. Use it when a caller needs "no committed mutation" rather than
    "retry-safe enough". *)
val is_strictly_read_only_tool : string -> bool

(** Negation of [is_effectively_read_only_tool]. *)
val has_mutating_side_effect : string -> bool

(** Input-aware read-only check for tools that mix read-only and mutating
    subcommands within one tool name. *)
val is_read_only_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Input-aware strict read-only check. This uses descriptor
    [readonly_of_input] when present and otherwise falls back to
    [is_strictly_read_only_tool]. *)
val is_strictly_read_only_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Input-aware main-worktree boundary check: returns [true] when the tool
    should NOT open the per-turn checkpoint boundary (read-only, MASC
    workspace, or playground-sandboxed mutations). *)
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

(** Replace injected MASC tool schemas.
    Startup calls this through [inject_masc_schemas]; runtime readers should
    use [masc_schemas_snapshot] rather than holding mutable state. *)
val set_masc_schemas : Masc_domain.tool_schema list -> unit

(** Immutable snapshot of injected MASC tool schemas. *)
val masc_schemas_snapshot : unit -> Masc_domain.tool_schema list

(** Names extracted from [masc_schemas_snapshot ()] in declaration order. *)
val injected_masc_tool_names : unit -> string list

(** SSOT schema for [keeper_tool_search]. Defined here because this
    module is the canonical owner of keeper-internal tool metadata. *)
val keeper_tool_search_schema : Masc_domain.tool_schema
