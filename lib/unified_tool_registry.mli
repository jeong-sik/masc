(** Unified Tool Registry Ratchet — P0-1.

    Single registration flow that fills dispatch-tag/schema gaps across
    [Keeper_tool_name], [Config.raw_all_tool_schemas], and the keeper task runtime.

    The flow is invoked once at startup by the MCP composition root; it is
    idempotent and preserves tags already registered via [Tool_spec]. *)

val tag_of_name : string -> Tool_dispatch.module_tag option
(** Derive the canonical dispatch tag for a tool name from naming heuristics
    and schema-owned closed clusters. Returns [None] for names that have no
    clear ratchet fallback; those must be covered by an explicit [Tool_spec]
    registration. *)

val register_all : unit -> unit
(** Register tags (+ placeholder schemas where needed) for all names in the
    unified name sources that are not already present in the tag registry. *)

val visible_schemas_missing_tags : unit -> string list
(** Return the names of LLM-visible schemas that still lack a dispatch tag.
    Empty when the ratchet is complete. *)

val enforce_visible_tag_coverage : unit -> unit
(** Startup invariant: raises [Failure] if any LLM-visible schema lacks a
    dispatch tag. *)
