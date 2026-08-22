val inject_agent_name_into_body :
  ?rewrite_existing:bool ->
  agent_name:string ->
  string ->
  string

val reduce : actor:string option -> auth_token:string option -> string -> string
