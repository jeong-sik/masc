
(** Tool_spec — Unified tool specification with compile-time safety.

    Replaces scattered registration across 6 separate systems with a single
    builder function and registration call. Required fields (name, description,
    module_tag, input_schema) are mandatory labeled arguments — omitting any
    of them is a compile error. Optional fields use fail-closed defaults.

    {b Usage:}
    {[
      let spec = Tool_spec.create
        ~name:"masc_compact_context"
        ~description:"Apply context compaction strategies"
        ~module_tag:Mod_compact
        ~input_schema:(...)
        ~is_read_only:true
        ~is_idempotent:true
        ()
      let () = Tool_spec.register spec
    ]}

    @since 2.196.0 *)

(** {1 Types} *)

(** How a tool's handler is bound to the dispatch registry. *)
type handler_binding =
  | Direct of Tool_dispatch.handler
  | Shared of Tool_dispatch.handler
  | Tag_dispatch

type t = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  module_tag : Tool_dispatch.module_tag;
  handler_binding : handler_binding;
  is_read_only : bool;
  mcp_context_required : bool;
  is_destructive : bool;
  is_idempotent : bool;
  visibility : Tool_catalog.visibility;
  implementation_status : Tool_catalog.implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  title : string option;
  effect_domain : Tool_catalog.effect_domain option;
  requires_actor_binding : bool option;
  required_permission : Masc_domain.permission option;
}

(** {1 Builder} *)

val create :
  name:string ->
  description:string ->
  module_tag:Tool_dispatch.module_tag ->
  input_schema:Yojson.Safe.t ->
  handler_binding:handler_binding ->
  ?is_read_only:bool ->
  ?mcp_context_required:bool ->
  ?is_destructive:bool ->
  ?is_idempotent:bool ->
  ?visibility:Tool_catalog.visibility ->
  ?implementation_status:Tool_catalog.implementation_status ->
  ?canonical_name:string ->
  ?replacement:string ->
  ?reason:string ->
  ?allow_direct_call_when_hidden:bool ->
  ?title:string ->
  ?effect_domain:Tool_catalog.effect_domain ->
  ?requires_actor_binding:bool ->
  ?required_permission:Masc_domain.permission ->
  unit -> t
(** Build a tool spec. The first five arguments are required (compile error
    if omitted). All optional arguments default to fail-closed values:
    booleans to [false], options to [None], visibility to [Default],
    implementation_status to [Real]. *)

(** {1 Registration} *)

val register : t -> unit
(** Register a tool spec into all dispatch subsystems atomically:
    - [Tool_dispatch.register_module_tag] (tag + schema)
    - [Tool_catalog.register_metadata] (visibility and semantic flags)

    @raise Invalid_argument if [name] is empty. *)

val register_all : t list -> unit
(** Bulk-register multiple specs. *)

(** {1 Conversion} *)

val to_tool_schema : t -> Masc_domain.tool_schema
(** Convert to [Masc_domain.tool_schema] for interop with existing schema-based APIs. *)

(** {1 Boot-time verification} *)

val verify_handler_coverage : unit -> string list
(** Returns tool names that were registered via [register] with [Direct] or
    [Shared] binding but have no handler in [Tool_dispatch]. [Tag_dispatch]
    bindings are excluded. Call after server initialization completes.
    Empty list means full coverage. *)

val all_registered_names : unit -> string list
