(** Tool_schemas_recurring — SSOT for recurring task tool schemas.
    RFC-0314 — Keeper Recurring Producer. *)

type operation =
  | Add
  | List
  | Remove

type definition =
  { operation : operation
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

val operation_id : operation -> string
val definitions : definition list
val schemas : Masc_domain.tool_schema list
