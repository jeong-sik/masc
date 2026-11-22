(** Tool_schemas_wiki — SSOT for wiki tool schemas. *)

type operation =
  | List_pages
  | Read_page
  | Create_page
  | Update_page
  | Search_pages
  | Lint_pages
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
  | Create_page -> "create"
  | Update_page -> "update"
  | Search_pages -> "search"
  | Lint_pages -> "lint"
;;

let definition operation ~read_only name =
  let loaded = Tool_definition_embedded.load name in
  { operation
  ; schema = loaded.Tool_definition_toml.schema
  ; keeper_projection = loaded.Tool_definition_toml.keeper_projection
  ; read_only
  }
;;

let definition_for = function
  | List_pages -> definition List_pages ~read_only:true "masc_wiki_list"
  | Read_page -> definition Read_page ~read_only:true "masc_wiki_read"
  | Create_page -> definition Create_page ~read_only:false "masc_wiki_create"
  | Update_page -> definition Update_page ~read_only:false "masc_wiki_update"
  | Search_pages -> definition Search_pages ~read_only:true "masc_wiki_search"
  | Lint_pages -> definition Lint_pages ~read_only:true "masc_wiki_lint"
;;

let definitions : definition list = List.map definition_for all_of_operation

let schemas = List.map (fun definition -> definition.schema) definitions
