(** Tool_shard_types_core — pure types and routing helpers shared by
    every tool schema submodule.

    - [shard] record (the unit granted/revoked at runtime)
    - [StringMap] alias used by the registry
    - Schema lookup helpers ([select_named_schemas], [default_shard_names])
    - MCP surface metadata ([tool_spec_read_only], [tool_spec_destructive],
      [tool_required_permission], [tool_effect_domain]) *)

type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap = Map.Make (String)

let select_named_schemas (names : string list) (schemas : Masc_domain.tool_schema list)
  : Masc_domain.tool_schema list
  =
  names
  |> List.filter_map (fun name ->
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      schemas)
;;

let default_shard_names : string list =
  [ "base"; "board"; "filesystem"; "shell"; "library"; "taskboard"; "coding" ]
;;

let tool_spec_read_only = [ "masc_tool_list" ]
let tool_spec_destructive = [ "masc_tool_grant"; "masc_tool_revoke" ]

let tool_required_permission = function
  | "masc_tool_list" -> Some Masc_domain.CanReadState
  | "masc_tool_grant" | "masc_tool_revoke" -> Some Masc_domain.CanAdmin
  | _ -> None
;;

let tool_effect_domain name =
  match Tool_name.of_string name with
  | Some (Tool_name.Masc Tool_name.Masc.Tool_list) -> Some Tool_catalog.Read_only
  | Some (Tool_name.Masc (Tool_name.Masc.Tool_grant | Tool_name.Masc.Tool_revoke)) ->
    Some Tool_catalog.Masc_coordination
  | _ -> None
;;
