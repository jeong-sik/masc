(** Tool_spec — Unified tool specification with compile-time safety.

    See [tool_spec.mli] for documentation.

    @since 2.196.0 *)

type handler_binding =
  | Direct of Tool_dispatch.handler
  | Shared of Tool_dispatch.handler
  | Tag_dispatch
  | Match_chain

type t = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  module_tag : Tool_dispatch.module_tag;
  handler_binding : handler_binding;
  is_read_only : bool;
  requires_join : bool;
  is_destructive : bool;
  is_idempotent : bool;
  visibility : Tool_catalog.visibility;
  lifecycle : Tool_catalog.lifecycle;
  implementation_status : Tool_catalog.implementation_status;
  canonical_name : string option;
  replacement : string option;
  reason : string option;
  allow_direct_call_when_hidden : bool;
  title : string option;
  required_permission : Types.permission option;
  effect_domain : Tool_catalog.effect_domain option;
  requires_actor_binding : bool option;
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
    ?(requires_join = false)
    ?(is_destructive = false)
    ?(is_idempotent = false)
    ?(visibility = Tool_catalog.Default)
    ?(lifecycle = Tool_catalog.Active)
    ?(implementation_status = Tool_catalog.Real)
    ?canonical_name
    ?replacement
    ?reason
    ?(allow_direct_call_when_hidden = false)
    ?title
    ?required_permission
    ?effect_domain
    ?requires_actor_binding
    () =
  { name; description; module_tag; input_schema; handler_binding;
    is_read_only; requires_join; is_destructive; is_idempotent;
    visibility; lifecycle; implementation_status;
    canonical_name; replacement; reason;
    allow_direct_call_when_hidden; title; required_permission; effect_domain;
    requires_actor_binding }

(* ================================================================ *)
(* Conversion                                                       *)
(* ================================================================ *)

let to_tool_schema (spec : t) : Types.tool_schema =
  { Types.name = spec.name;
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
  if spec.name = "" then
    invalid_arg "Tool_spec.register: name must not be empty";
  (* Track for handler coverage verification *)
  Hashtbl.replace registered_names spec.name ();
  (* 1. Tag + schema registry *)
  Tool_dispatch.register_module_tag
    ~schemas:[ to_tool_schema spec ] ~tag:spec.module_tag;
  (* 2. Read-only set *)
  if spec.is_read_only then
    Tool_dispatch.init_read_only_set [ spec.name ];
  (* 3. Requires-join set *)
  if spec.requires_join then
    Tool_dispatch.init_requires_join_set [ spec.name ];
  (* Add destructive and idempotent sets *)
  if spec.is_destructive then
    Tool_dispatch.init_destructive_set [ spec.name ];
  if spec.is_idempotent then
    Tool_dispatch.init_idempotent_set [ spec.name ];
  (* 4. Catalog metadata — enforce Hidden for System_internal tools *)
  let is_system_internal =
    Tool_catalog_surfaces.is_on_surface System_internal spec.name
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
    | None when spec.requires_join -> Some true
    | None ->
        Option.bind existing (fun (meta : Tool_catalog.metadata) ->
          meta.requires_actor_binding)
  in
  Tool_catalog.register_metadata spec.name
    { Tool_catalog.visibility = effective_visibility;
      lifecycle = spec.lifecycle;
      implementation_status = spec.implementation_status;
      canonical_name = spec.canonical_name;
      replacement = spec.replacement;
      reason = spec.reason;
      allow_direct_call_when_hidden = effective_allow_direct;
      readonly = Some spec.is_read_only;
      destructive = Some spec.is_destructive;
      idempotent = Some spec.is_idempotent;
      required_permission = spec.required_permission;
      effect_domain = spec.effect_domain;
      requires_actor_binding };
  (* 5. Handler binding — auto-register Direct/Shared into Tool_dispatch *)
  (match spec.handler_binding with
   | Direct h | Shared h ->
     Tool_dispatch.register ~tool_name:spec.name ~handler:h;
     Hashtbl.replace expects_handler spec.name ()
   | Tag_dispatch | Match_chain -> ())

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
