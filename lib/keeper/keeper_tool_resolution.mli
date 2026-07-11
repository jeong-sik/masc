(** Keeper_tool_resolution — typed resolution for policy tool name validation.

    RFC-0080 Phase 2. Replaces the legacy multi-source OR boolean check with
    a typed [resolve] function that returns provenance information.

    @since 2.219.0 *)

(** Which source admitted a tool name during resolution. *)
type tried_source =
  | Dispatch_table              (** Tool_dispatch.is_registered *)
  | Public_descriptor           (** Keeper_tool_descriptor.find_public *)
  | Alias_internal              (** Keeper_tool_alias.is_known_internal *)
  | Registry_internal_candidate (** keeper_internal_candidate_tool_names *)
  | Registry_core_tools         (** effective_core_tools *)
  | Tool_schema                 (** Tool_shard.all_keeper_tool_schemas + inline schemas *)
  | Descriptor_registry         (** Keeper-tool candidate names projected by
                                    Keeper_tool_descriptor.all_descriptors *)
  | System_internal             (** Tool_catalog_surfaces.is_system_internal_hidden — system-internal
                                    tools hidden from keeper surfaces but still real/dispatchable *)

(** Resolution outcome for a tool name. *)
type resolution =
  | Resolved of { canonical : string; via : tried_source }
  | Alias_to of { from_ : string; canonical : string; via : tried_source }
  | Unknown of { name : string; tried : tried_source list }

(** Resolve a tool name through the source chain.
    Short-circuits on first hit, same order as the current source chain. *)
val resolve : string -> resolution

(** Human-readable label for a single source. *)
val string_of_tried_source : tried_source -> string

(** Comma-separated list of source labels. *)
val string_of_tried : tried_source list -> string

(** Full-probe analysis: return every source that would admit [name].
    Unlike [resolve] which short-circuits, checks every current source. *)
val all_admitting_sources : string -> tried_source list

(** RFC-0084 §1.4 — Single-SSOT entry for runtime tool-name routing. *)

type runtime_decision_outcome =
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

(** [runtime_decision name] returns the pure routing decision for a
    runtime-reported or model-reported tool name. This module is the
    low-dependency SSOT for runtime tool-name routing.

    Result variants:
    - [Route_hit { internal }] — alias-table hit; internal name returned.
    - [Already_internal { canonical }] — name is already in internal form.
    - [Miss] — name does not resolve through any runtime route. *)
val runtime_decision : string -> runtime_decision_outcome

(** Pure canonicalisation — no telemetry side-effect.

    Used by set-logic call sites (tool canonicalisation, surface
    composition, satisfaction checks) where every invocation should NOT
    count as an observation event. *)
val canonical_tool_name : string -> string

(** Observation-emitting canonicalisation.

    Emits exactly one [masc_keeper_tool_call_total] sample with bounded
    [tool] / [routed_to] / [result] labels. Use only at the keeper turn
    observation boundary. Non-observation call sites should use
    [canonical_tool_name] to avoid double-counting. *)
val canonical_tool_name_observed : string -> string

(** Return a schema-allowed correction when a tool call uses a keeper-internal
    implementation name whose public alias is the supported LLM surface. *)
val public_alias_guidance_for_internal_call
  :  allowed_tool_names:string list -> string -> string option
