(** Tool_spec — Unified tool specification with compile-time safety.

    See [tool_spec.mli] for documentation. *)

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

(* ================================================================ *)
(* Builder                                                          *)
(* ================================================================ *)

let create
    ~name
    ~description
    ~module_tag
    ~input_schema
    ~handler_binding
    ?(is_read_only = false)
    ?(mcp_context_required = false)
    ?(is_idempotent = false)
    ?(visibility = Tool_catalog.Default)
    ?(implementation_status = Tool_catalog.Real)
    ?reason
    ?(allow_direct_call_when_hidden = false)
    ?title
    () =
  { name; description; module_tag; input_schema; handler_binding;
    is_read_only; mcp_context_required; is_idempotent;
    visibility; implementation_status;
    reason;
    allow_direct_call_when_hidden; title }

(* ================================================================ *)
(* Conversion                                                       *)
(* ================================================================ *)

let to_tool_schema (spec : t) : Masc_domain.tool_schema =
  { Masc_domain.name = spec.name;
    description = spec.description;
    input_schema = spec.input_schema }

(* ================================================================ *)
(* Registration                                                     *)
(* ================================================================ *)

let register (spec : t) =
  if String.equal spec.name "" then
    invalid_arg "Tool_spec.register: name must not be empty";
  (* 1. Catalog metadata. Registration preserves the typed declaration;
     product-name membership must not override visibility. *)
  (match Tool_catalog.registered_metadata spec.name with
   | None ->
     invalid_arg
       ("Tool_spec.register: tool " ^ spec.name
        ^ " has no catalog-owned metadata")
   | Some authority ->
     match
       Tool_catalog.register_runtime_metadata spec.name
         { authority with
           visibility = spec.visibility;
           implementation_status = spec.implementation_status;
           reason = spec.reason;
           allow_direct_call_when_hidden = spec.allow_direct_call_when_hidden;
           readonly = Some spec.is_read_only;
           mcp_context_required = Some spec.mcp_context_required;
           idempotent = Some spec.is_idempotent }
     with
     | Ok () -> ()
     | Error detail -> invalid_arg ("Tool_spec.register: " ^ detail)
  );
  (* 2. Tag + schema registry. An unclassified tool cannot reach this point. *)
  Tool_dispatch.register_module_tag
    ~schemas:[ to_tool_schema spec ] ~tag:spec.module_tag;
  (* 3. Handler binding. *)
  (match spec.handler_binding with
   | Registered h ->
     Tool_dispatch.register ~tool_name:spec.name ~handler:h
   | Tag_dispatch -> ())

let register_all (specs : t list) =
  List.iter register specs
