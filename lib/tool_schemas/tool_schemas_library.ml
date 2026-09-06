(** Tool_schemas_library — SSOT for library tool schemas. *)

type operation =
  | List_documents
  | Read_document
  | Add_document
  | Search_documents
[@@deriving enumerate]

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; keeper_projection : Masc_domain.tool_schema option
  ; read_only : bool
  }

let operation_id = function
  | List_documents -> "list"
  | Read_document -> "read"
  | Add_document -> "add"
  | Search_documents -> "search"
;;

let definition operation ~read_only (loaded : Tool_definition_toml.loaded) =
  { operation
  ; schema = loaded.schema
  ; keeper_projection = loaded.keeper_projection
  ; read_only
  }
;;

let definition_for = function
  (* masc_library_list *)
  | List_documents -> definition List_documents ~read_only:true Tool_schemas_library_toml.list
  (* masc_library_read *)
  | Read_document -> definition Read_document ~read_only:true Tool_schemas_library_toml.read
  (* masc_library_add *)
  | Add_document -> definition Add_document ~read_only:false Tool_schemas_library_toml.add
  (* masc_library_search *)
  | Search_documents ->
    definition Search_documents ~read_only:true Tool_schemas_library_toml.search
;;

let definitions : definition list = List.map definition_for all_of_operation

let schemas = List.map (fun definition -> definition.schema) definitions
