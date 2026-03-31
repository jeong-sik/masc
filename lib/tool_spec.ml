(** Tool_spec — Unified tool specification with compile-time safety.

    See [tool_spec.mli] for documentation.

    @since 2.196.0 *)

type t = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  module_tag : Tool_dispatch.module_tag;
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
}

(* ================================================================ *)
(* Builder                                                          *)
(* ================================================================ *)

let create
    ~name
    ~description
    ~module_tag
    ~input_schema
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
    () =
  { name; description; module_tag; input_schema;
    is_read_only; requires_join; is_destructive; is_idempotent;
    visibility; lifecycle; implementation_status;
    canonical_name; replacement; reason;
    allow_direct_call_when_hidden; title }

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
  (* 4. Catalog metadata *)
  Tool_catalog.register_metadata spec.name
    { Tool_catalog.visibility = spec.visibility;
      lifecycle = spec.lifecycle;
      implementation_status = spec.implementation_status;
      canonical_name = spec.canonical_name;
      replacement = spec.replacement;
      reason = spec.reason;
      allow_direct_call_when_hidden = spec.allow_direct_call_when_hidden;
      readonly = Some spec.is_read_only;
      destructive = Some spec.is_destructive;
      idempotent = Some spec.is_idempotent }

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
  ) registered_names;
  !missing
