(** Tool_schemas_library — SSOT for library tool schemas. *)



type operation =
  | List_documents
  | Read_document
  | Add_document
  | Search_documents

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

let operation_id = function
  | List_documents -> "list"
  | Read_document -> "read"
  | Add_document -> "add"
  | Search_documents -> "search"
;;

let definitions : definition list = [
  (* masc_library_list *)
  { operation = List_documents; read_only = true; schema = Tool_schemas_library_toml.list };

  (* masc_library_read *)
  { operation = Read_document; read_only = true; schema = Tool_schemas_library_toml.read };

  (* masc_library_add *)
  { operation = Add_document; read_only = false; schema = Tool_schemas_library_toml.add };

  (* masc_library_search *)
  { operation = Search_documents; read_only = true; schema = Tool_schemas_library_toml.search };
]

let schemas = List.map (fun definition -> definition.schema) definitions
