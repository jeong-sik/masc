(** Tool_shard_types_core — pure types and routing helpers shared by
    every tool schema submodule.

    - [shard] record (the unit granted/revoked at runtime)
    - [StringMap] alias used by the registry
    - Schema lookup helpers ([select_named_schemas], [default_shard_names])
    - MCP surface read-only metadata ([tool_spec_read_only]) *)

type shard =
  { name : string
  ; tools : Masc_domain.tool_schema list
  ; read_only_tools : string list
  ; removable : bool
  ; description : string
  }

module StringMap = Set_util.StringMap

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
  [ "base"; "board"; "filesystem"; "search_files"; "library"; "surface"
  ; "taskboard" ]
;;

let tool_spec_read_only = []
