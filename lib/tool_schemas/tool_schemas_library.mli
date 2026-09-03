type operation =
  | List_documents
  | Read_document
  | Add_document
  | Search_documents

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
      (** The catalog row, published to MCP clients. *)
  ; keeper_projection : Masc_domain.tool_schema option
      (** The file's [keeper_projection] table when it declares one: the
          sentence and input shape a Keeper reads instead of the row. *)
  ; read_only : bool
  }

val operation_id : operation -> string
val definitions : definition list
val schemas : Masc_domain.tool_schema list
