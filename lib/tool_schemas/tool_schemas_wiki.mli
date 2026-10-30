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
      (** The catalog row, published to MCP clients. *)
  ; keeper_projection : Masc_domain.tool_schema option
      (** The file's [keeper_projection] table when it declares one: the
          sentence and input shape a Keeper reads instead of the row. *)
  ; read_only : bool
  }

val operation_id : operation -> string
val definitions : definition list
val schemas : Masc_domain.tool_schema list
