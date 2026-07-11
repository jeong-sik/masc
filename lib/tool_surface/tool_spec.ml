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

(** Tool_spec — Unified tool specification with compile-time safety.

    See [tool_spec.mli] for documentation.

    @since 2.196.0 *)

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
    ?(is_destructive = false)
    ?(is_idempotent = false)
    ?(visibility = Tool_catalog.Default)
    ?(implementation_status = Tool_catalog.Real)
    ?canonical_name
    ?replacement
    ?reason
    ?(allow_direct_call_when_hidden = false)
    ?title
    ?effect_domain
    ?requires_actor_binding
    ?required_permission
    () =
  { name; description; module_tag; input_schema; handler_binding;
    is_read_only; mcp_context_required; is_destructive; is_idempotent;
    visibility; implementation_status;
    canonical_name; replacement; reason;
    allow_direct_call_when_hidden; title; effect_domain;
    requires_actor_binding; required_permission }

(* ================================================================ *)
(* Conversion                                                       *)
(* ================================================================ *)

let to_tool_schema (spec : t) : Masc_domain.tool_schema =
  { Masc_domain.name = spec.name;
    description = spec.description;
    input_schema = spec.input_schema }

(* ================================================================ *)
(* Registration tracking (for verify_handler_coverage)              *)
(* ================================================================ *)

let registered_names : (string, unit) Hashtbl.t = Hashtbl.create 256
let expects_handler : (string, unit) Hashtbl.t = Hashtbl.create 256

(* ================================================================ *)
(* Registration                                                     *)
(* ================================================================ *)

let register (spec : t) =
  if String.equal spec.name "" then
    invalid_arg "Tool_spec.register: name must not be empty";
  (* Track for handler coverage verification *)
  Hashtbl.replace registered_names spec.name ();
  (* 1. Tag + schema registry *)
  Tool_dispatch.register_module_tag
    ~schemas:[ to_tool_schema spec ] ~tag:spec.module_tag;
  (* 2. Catalog metadata — enforce Hidden for system-internal tools *)
  let is_system_internal =
    Tool_catalog_surfaces.is_system_internal_hidden spec.name
  in
  let effective_visibility =
    if is_system_internal && spec.visibility = Tool_catalog.Default
    then Tool_catalog.Hidden
    else spec.visibility
  in
  let effective_allow_direct =
    spec.allow_direct_call_when_hidden || is_system_internal
  in
  let existing = Tool_catalog.registered_metadata spec.name in
  let requires_actor_binding =
    match spec.requires_actor_binding with
    | Some _ as value -> value
    | None ->
        Option.bind existing (fun (meta : Tool_catalog.metadata) ->
          meta.requires_actor_binding)
  in
  let required_permission =
    match spec.required_permission with
    | Some value -> value
    | None ->
        (Tool_catalog.metadata spec.name).required_permission
  in
  Tool_catalog.register_metadata spec.name
    { Tool_catalog.visibility = effective_visibility;
      lifecycle = Tool_catalog.Active;
      implementation_status = spec.implementation_status;
      canonical_name = spec.canonical_name;
      replacement = spec.replacement;
      reason = spec.reason;
      allow_direct_call_when_hidden = effective_allow_direct;
      readonly = Some spec.is_read_only;
      mcp_context_required = Some spec.mcp_context_required;
      destructive = Some spec.is_destructive;
      idempotent = Some spec.is_idempotent;
      effect_domain = spec.effect_domain;
      requires_actor_binding;
      required_permission };
  (* 3. Handler binding — auto-register Direct/Shared into Tool_dispatch *)
  (match spec.handler_binding with
   | Direct h | Shared h ->
     Tool_dispatch.register ~tool_name:spec.name ~handler:h;
     Hashtbl.replace expects_handler spec.name ()
   | Tag_dispatch -> ())

let register_all (specs : t list) =
  List.iter register specs

(* ================================================================ *)
(* Boot-time verification                                           *)
(* ================================================================ *)

let verify_handler_coverage () =
  let missing = ref [] in
  Hashtbl.iter (fun name () ->
    if not (Tool_dispatch.is_registered name) then
      missing := name :: !missing
  ) expects_handler;
  !missing

let all_registered_names () =
  Hashtbl.fold (fun name () acc -> name :: acc) registered_names []
