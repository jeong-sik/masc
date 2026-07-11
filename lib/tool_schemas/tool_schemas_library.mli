type operation =
  | List_documents
  | Read_document
  | Add_document
  | Promote_document
  | Search_documents

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

val operation_id : operation -> string
val definitions : definition list
val schemas : Masc_domain.tool_schema list
