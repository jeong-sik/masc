(** Unified Tool Registry Ratchet — P0-1.

    Single registration flow that fills dispatch-tag/schema gaps from
    [Config.raw_all_tool_schemas] and [Keeper_tool_descriptor].

    The flow is invoked once at startup by the MCP composition root; it is
    idempotent and preserves tags already registered via [Tool_spec]. *)

val tag_of_name : string -> Tool_dispatch.module_tag option
(** Exact lookup from canonical schema membership or a typed descriptor. *)

val tag_of_runtime_handler :
  Keeper_tool_descriptor.runtime_handler -> Tool_dispatch.module_tag

val register_all : unit -> unit
(** Register tags and their owning schemas for all names in the unified name
    sources that are not already present in the tag registry. *)

val visible_schemas_missing_tags : unit -> string list
(** Return the names of LLM-visible schemas that still lack a dispatch tag.
    Empty when the ratchet is complete. *)

val enforce_visible_tag_coverage : unit -> unit
(** Startup invariant: raises [Failure] if any LLM-visible schema lacks a
    dispatch tag. *)
