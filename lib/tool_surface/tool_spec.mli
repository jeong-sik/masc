
(** Tool_spec — Unified tool specification with compile-time safety.

    Required fields (name, description, module_tag, input_schema) are mandatory
    labeled arguments. Optional fields use fail-closed defaults.

    {b Usage:}
    {[
      let spec = Tool_spec.create
        ~name:"masc_library_search"
        ~description:"Search stored library entries"
        ~module_tag:Mod_library
        ~input_schema:(...)
        ~is_read_only:true
        ~is_idempotent:true
        ()
      let () = Tool_spec.register spec
    ]} *)

(** {1 Types} *)

(** How a tool's handler is bound to the dispatch registry. *)
type handler_binding =
  | Registered of Tool_dispatch.handler
  | Tag_dispatch

type t = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  module_tag : Tool_dispatch.module_tag;
  handler_binding : handler_binding;
  is_read_only : bool;
  mcp_context_required : bool;
  is_idempotent : bool;
  visibility : Tool_catalog.visibility;
  implementation_status : Tool_catalog.implementation_status;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  title : string option;
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
  ?is_idempotent:bool ->
  ?visibility:Tool_catalog.visibility ->
  ?implementation_status:Tool_catalog.implementation_status ->
  ?reason:string ->
  ?allow_direct_call_when_hidden:bool ->
  ?title:string ->
  unit -> t
(** Build a tool spec. The first five arguments are required (compile error
    if omitted). All optional arguments default to fail-closed values:
    booleans to [false], options to [None], visibility to [Default],
    implementation_status to [Real]. *)

(** {1 Registration} *)

val register : t -> unit
(** Register a tool spec into all dispatch subsystems atomically:
    - [Tool_dispatch.register_module_tag] (tag + schema)
    - [Tool_catalog.register_runtime_metadata] (visibility and semantic flags,
      preserving the catalog-owned permission)

    @raise Invalid_argument if [name] is empty. *)

val register_all : t list -> unit
(** Bulk-register multiple specs. *)

(** {1 Conversion} *)

val to_tool_schema : t -> Masc_domain.tool_schema
(** Convert to [Masc_domain.tool_schema] for interop with existing schema-based APIs. *)
