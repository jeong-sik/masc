(** Keeper_tool_surfaces — lightweight internal tool surface
    definitions.

    This module stays dependency-light so spawned agents can share
    allowlists without pulling in the full public capability
    registry.

    - **Spawned-agent**: tools available to MCP-spawned agent
      sub-processes (a small public set for scripting agents). *)

(** {1 Helpers} *)

(** [unique_preserve_order xs] removes duplicates from [xs] while
    preserving first-occurrence order.  Thin alias over
    {!Json_util.dedupe_keep_order} re-exported for siblings. *)

val lookup_schemas_by_name_exn :
  label:string ->
  Masc_domain.tool_schema list ->
  string list ->
  Masc_domain.tool_schema list
(** [lookup_schemas_by_name_exn ~label all_schemas values] returns
    the schemas in [all_schemas] whose names appear in [values],
    raising [Invalid_argument "<label>: unknown tool schema(s): <list>"]
    when any requested name is missing.

    Raises rather than returning [Result] because every caller in
    this module uses it during static initialisation; an unknown
    name there is a developer error, not a runtime condition. *)
