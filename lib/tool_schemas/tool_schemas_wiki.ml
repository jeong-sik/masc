(** Tool_schemas_wiki — SSOT for wiki tool schemas. *)

type operation =
  | List_pages
  | Read_page
  | Add_page
  | Search_pages
[@@deriving enumerate]

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; keeper_projection : Masc_domain.tool_schema option
  ; read_only : bool
  }

let operation_id = function
  | List_pages -> "list"
  | Read_page -> "read"
  | Add_page -> "add"
  | Search_pages -> "search"
;;

let definition operation ~read_only (loaded : Tool_definition_toml.loaded) =
  { operation
  ; schema = loaded.schema
  ; keeper_projection = loaded.keeper_projection
  ; read_only
  }
;;

let definition_for = function
  (* masc_wiki_list *)
  | List_pages -> definition List_pages ~read_only:true Tool_schemas_wiki_toml.list
  (* masc_wiki_read *)
  | Read_page -> definition Read_page ~read_only:true Tool_schemas_wiki_toml.read
  (* masc_wiki_add *)
  | Add_page -> definition Add_page ~read_only:false Tool_schemas_wiki_toml.add
  (* masc_wiki_search *)
  | Search_pages ->
    definition Search_pages ~read_only:true Tool_schemas_wiki_toml.search
;;

let definitions : definition list = List.map definition_for all_of_operation

let schemas = List.map (fun definition -> definition.schema) definitions
