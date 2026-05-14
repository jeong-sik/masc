(** Tool_resolution — typed resolution for policy tool name validation.

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
