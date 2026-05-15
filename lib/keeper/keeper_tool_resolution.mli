(** Keeper_tool_resolution — typed resolution for policy tool name validation.

    RFC-0080 Phase 2. Replaces the 15-fold OR boolean check with a typed
    [resolve] function that returns provenance information.

    @since 2.219.0 *)

(** Which source admitted a tool name during resolution. *)
type tried_source =
  | Dispatch_table              (** Tool_dispatch.is_registered *)
  | Tool_name_variant           (** Tool_name.of_string *)
  | Alias_route                 (** Keeper_tool_alias.route *)
  | Alias_internal              (** Keeper_tool_alias.is_known_internal *)
  | Alias_masc_to_internal      (** Keeper_tool_alias.public_masc_to_internal *)
  | Registry_internal_candidate (** keeper_internal_candidate_tool_names *)
  | Registry_core_tools         (** effective_core_tools *)
  | Registry_admin_dispatched   (** keeper_admin_dispatched_tools *)
  | Shard_schema                (** Tool_shard.all_keeper_tool_schemas *)
  | Surface of Tool_catalog_surfaces.surface

(** Resolution outcome for a tool name. *)
type resolution =
  | Resolved of { canonical : string; via : tried_source;
                  surface : Tool_catalog_surfaces.surface option }
  | Alias_to of { from_ : string; canonical : string; via : tried_source }
  | Unknown of { name : string; tried : tried_source list }

(** Resolve a tool name through the source chain.
    Short-circuits on first hit, same order as the original 15-fold OR. *)
val resolve : string -> resolution

(** Legacy adapter: [true] if resolved or aliased, [false] if unknown.
    Drop-in replacement for [Keeper_tool_policy_config.is_known_policy_tool_name]. *)
val is_known_policy_tool_name : string -> bool

(** Human-readable label for a single source. *)
val string_of_tried_source : tried_source -> string

(** Comma-separated list of source labels. *)
val string_of_tried : tried_source list -> string

(** Full-probe analysis: return every source that would admit [name].
    Unlike [resolve] which short-circuits, checks all 13 sources.
    For source-overlap analysis (Phase 5). *)
val all_admitting_sources : string -> tried_source list

(** RFC-0084 §1.4 — Single-SSOT entry for runtime tool-name routing. *)

type runtime_decision_outcome =
  | Mcp_mapped of
      { stripped : string
      ; internal : string
      }
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

(** [runtime_decision name] returns the pure routing decision for a
    runtime-reported or model-reported tool name. PR-6 establishes this
    as the low-dependency SSOT entry; [Keeper_tool_disclosure] delegates
    to it for parity during migration. PR-7 (keeper turn), PR-8 (MCP
    server), PR-9 (tag-dispatch) migrate runtime callers to this entry.
    PR-11 removes the legacy disclosure wrapper.

    Result variants:
    - [Mcp_mapped { stripped; internal }] — name was an MCP-prefixed
      public alias resolved to an internal canonical name.
    - [Route_hit { internal }] — alias-table hit; internal name returned.
    - [Already_internal { canonical }] — name is already in internal form.
    - [Miss] — name does not resolve through any disclosure path. *)
val runtime_decision : string -> runtime_decision_outcome
