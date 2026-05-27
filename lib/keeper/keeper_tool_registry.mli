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

(** Negation of [is_effectively_read_only_tool]. *)
val has_mutating_side_effect : string -> bool

(** Input-aware read-only check for tools that mix read-only and mutating
    subcommands within one tool name. *)
val is_read_only_with_input :
  tool_name:string -> input:Yojson.Safe.t -> bool

(** Input-aware follow-up checkpoint decision. Read-only calls and tools whose
    descriptor/catalog effect domain is coordination or playground-scoped can
    continue without opening a repo checkpoint gate. *)
val allows_followup_checkpoint_with_input :
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

(** Scoped schema override for tests that need a synthetic MASC surface. *)
val with_masc_schemas_for_test :
  Masc_domain.tool_schema list -> (unit -> 'a) -> 'a

(** Names extracted from [masc_schemas_snapshot ()] in declaration order. *)
val injected_masc_tool_names : unit -> string list

(** SSOT schema for [keeper_tool_search]. Defined here because this
    module is the canonical owner of keeper-internal tool metadata.
    Consumed by [Keeper_tool_policy.keeper_default_model_tools]. *)
val keeper_tool_search_schema : Masc_domain.tool_schema
