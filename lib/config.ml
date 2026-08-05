(** Tool schema registry and visibility helpers. *)

module StringSet = Set_util.StringSet

(* Project every descriptor-owned masc_* backend schema into the substrate so
   the keeper tool universe knows the tool exists.  This includes the web
   backends (masc_web_search / masc_web_fetch), which the LLM reaches via their
   WebSearch / WebFetch public_names.

   Do NOT trim "keeper-only" tools out of this projection to keep them off the
   operator MCP surface.  [raw_all_tool_schemas] feeds both the keeper universe
   and the public MCP surface, and the operator-surface
   exclusion is enforced separately and downstream by [Tool_catalog.is_public_mcp]
   / [public_mcp_surface_tools] (contract stated in tool_schemas_misc.mli).
   The Keeper model surface itself comes directly from descriptors. *)
let descriptor_owned_internal_tool_schemas : Masc_domain.tool_schema list =
  Keeper_tool_descriptor.public_descriptors
  |> List.filter_map (fun (descriptor : Keeper_tool_descriptor.t) ->
    if String.starts_with ~prefix:"masc_" descriptor.internal_name
    then
      Some
        { Masc_domain.name = descriptor.internal_name
        ; description = descriptor.description
        ; input_schema = descriptor.input_schema
        }
    else None)

let raw_all_tool_schemas : Masc_domain.tool_schema list =
  Tool_shard.all_keeper_tool_schemas
  @ Tools.raw_schemas
  @ Tool_schemas_misc.schemas
  @ descriptor_owned_internal_tool_schemas
  @ Board_tool.tools
  @ Keeper_schema.schemas
  @ Tool_local_runtime.schemas
  @ Tool_agent_timeline.schemas

let front_door_tool_schemas : Masc_domain.tool_schema list = raw_all_tool_schemas

(** Validate tool schemas at module initialization time.
    Logs warnings for: duplicate names, empty names/descriptions,
    input_schema.type not "object". Does not block startup. *)
let validate_schemas (schemas : Masc_domain.tool_schema list) =
  let errors, _ =
    List.fold_left
      (fun (errors, seen) (schema : Masc_domain.tool_schema) ->
        let errors =
          if StringSet.mem schema.name seen then
            Printf.sprintf "Duplicate tool name: %s" schema.name :: errors
          else errors
        in
        let seen = StringSet.add schema.name seen in
        let errors =
          if schema.name = "" then "Empty tool name found" :: errors
          else errors
        in
        let errors =
          if schema.description = "" then
            Printf.sprintf "Empty description for tool: %s" schema.name
            :: errors
          else errors
        in
        let errors =
          match Json_util.assoc_member_opt "type" schema.input_schema with
          | Some (`String "object") -> errors
          | _ ->
              Printf.sprintf "Tool %s: input_schema.type is not 'object'"
                schema.name
              :: errors
        in
        (errors, seen))
      ([], StringSet.empty)
      schemas
  in
  match errors with
  | [] -> ()
  | errs -> invalid_arg (String.concat "; " (List.rev errs))

let () = validate_schemas raw_all_tool_schemas

let all_tool_schemas : Masc_domain.tool_schema list =
  let schemas =
    Capability_registry.public_tool_schemas_from front_door_tool_schemas
  in
  validate_schemas schemas;
  schemas

let all_tool_names () : string list =
  List.map (fun (s : Masc_domain.tool_schema) -> s.name) all_tool_schemas

let is_tool_allowed tool_name =
  Tool_catalog.is_visible tool_name

(* O(1) membership lookup for "is this name in raw_all_tool_schemas?". *)
let raw_tool_name_set : (string, unit) Hashtbl.t =
  let tbl = Hashtbl.create (List.length raw_all_tool_schemas * 2) in
  List.iter
    (fun (schema : Masc_domain.tool_schema) ->
      Hashtbl.replace tbl schema.name ())
    raw_all_tool_schemas;
  tbl

let is_raw_tool_name name = Hashtbl.mem raw_tool_name_set name

let visible_tool_schemas ?(include_hidden = false) () :
    Masc_domain.tool_schema list =
  Capability_registry.visible_public_tool_schemas_from ~include_hidden
    front_door_tool_schemas
