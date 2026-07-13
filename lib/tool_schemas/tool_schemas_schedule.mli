type action =
  | Create_request
  | List_requests
  | Get_request
  | Cancel_request

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }

val definitions : definition list
val schemas : Masc_domain.tool_schema list
val find_definition : string -> definition option
