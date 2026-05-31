(** Tool alias routing shared by tool-surface and keeper callers. *)

type route =
  { internal_name : string
  ; translate : Yojson.Safe.t -> Yojson.Safe.t
  ; public_schema : Yojson.Safe.t option
  ; descriptor : Agent_tool_descriptor.t
  }

let routing_table : (string, route) Hashtbl.t =
  let t = Hashtbl.create 8 in
  List.iter
    (fun (d : Agent_tool_descriptor.t) ->
      Hashtbl.replace
        t
        d.public_name
        { internal_name = d.internal_name
        ; translate = d.translate
        ; public_schema = Some d.input_schema
        ; descriptor = d
        })
    Agent_tool_descriptor.public_descriptors;
  t
;;

let route name = Hashtbl.find_opt routing_table name
let is_known_public name = Hashtbl.mem routing_table name

let known_internal_names_tbl : (string, unit) Hashtbl.t =
  let t = Hashtbl.create 128 in
  Hashtbl.iter
    (fun _ r ->
      List.iter
        (fun internal_name -> Hashtbl.replace t internal_name ())
        (Agent_tool_descriptor.internal_names r.descriptor))
    routing_table;
  List.iter
    (fun internal ->
      Hashtbl.replace t internal ();
      match Tool_catalog_surfaces.keeper_internal_replacement internal with
      | Some public -> Hashtbl.replace t public ()
      | None -> ())
    Tool_catalog_surfaces.keeper_internal_tools;
  List.iter
    (fun public_mcp -> Hashtbl.replace t public_mcp ())
    Tool_catalog_surfaces.public_mcp_surface_tools;
  t
;;

let is_known_internal name = Hashtbl.mem known_internal_names_tbl name
let public_names = Agent_tool_descriptor.public_names
let public_name_for_internal = Agent_tool_descriptor.public_name_for_internal

let public_masc_to_internal_tbl =
  let t = Hashtbl.create 16 in
  List.iter
    (fun internal ->
      match Tool_catalog_surfaces.keeper_internal_replacement internal with
      | Some public -> Hashtbl.replace t public internal
      | None -> ())
    Tool_catalog_surfaces.keeper_internal_tools;
  t
;;

let public_masc_to_internal name = Hashtbl.find_opt public_masc_to_internal_tbl name

let strip_mcp_masc_prefix name =
  if String.starts_with ~prefix:"mcp__masc__" name
  then String.sub name 11 (String.length name - 11)
  else name
;;

type canonical_resolution =
  | Public_mcp of
      { stripped : string
      ; internal : string
      }
  | Public_alias of { internal : string }
  | Internal of { canonical : string }
  | Unknown

let canonical_resolution name =
  let stripped = strip_mcp_masc_prefix name in
  match public_masc_to_internal stripped with
  | Some internal -> Public_mcp { stripped; internal }
  | None ->
    (match route stripped with
     | Some r -> Public_alias { internal = r.internal_name }
     | None ->
       if is_known_internal stripped then Internal { canonical = stripped } else Unknown)
;;

let canonical_internal_name name =
  match canonical_resolution name with
  | Public_mcp { internal; _ }
  | Public_alias { internal } -> Some internal
  | Internal { canonical } -> Some canonical
  | Unknown -> None
;;

let public_input_schema public = Agent_tool_descriptor.public_input_schema public
let translate_input ~public input = Agent_tool_descriptor.translate_input ~public input
