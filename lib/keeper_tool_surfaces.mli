module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

(** Keeper_tool_surfaces — lightweight internal tool surface
    definitions.

    This module stays dependency-light so spawned agents, local
    workers, and strict worker flows can share allowlists without
    pulling in the full public capability registry.

    Three surface families are exposed:

    - **Spawned-agent**: tools available to MCP-spawned agent
      sub-processes (a small public set for scripting agents).
    - **Local-worker**: tools available to in-process worker
      flows (a larger set including SDK contract schemas).
    - **Role-catalogue**: dynamic role-based filtering for the
      autonomous agent (worker / workspace_lead / fleet_leader). *)

(** {1 Helpers} *)

(** [unique_preserve_order xs] removes duplicates from [xs] while
    preserving first-occurrence order.  Thin alias over
    {!Json_util.dedupe_keep_order} re-exported for siblings. *)

val dedupe_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** [dedupe_schemas schemas] removes duplicate-by-[name] entries
    while preserving first-occurrence order. *)

(** [lookup_schemas_by_name_exn ~label all_schemas values] returns
    the schemas in [all_schemas] whose names appear in [values],
    raising [Invalid_argument "<label>: unknown tool schema(s): <list>"]
    when any requested name is missing.

    Raises rather than returning [Result] because every caller in
    this module uses it during static initialisation; an unknown
    name there is a developer error, not a runtime condition. *)

(** {1 Spawned-agent surface} *)

val spawned_agent_public_tool_names : string list
(** SSOT: {!Tool_catalog_surfaces.spawned_agent_surface_tools}.  The small
    set of tools a spawned scripting agent can use. *)

