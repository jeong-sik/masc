val inject_agent_name_into_body :
  ?rewrite_existing:bool ->
  ?strip_token:bool ->
  agent_name:string ->
  string ->
  string

val canonicalize_tool_arguments :
  actor:string ->
  auth_token:string option ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** Replace the internal caller marker with the transport-authenticated
    [actor] and remove the legacy argument-scoped token when transport auth is
    present. Tool-domain [agent_name] is preserved. This is the SSOT shared by
    HTTP body reduction and gRPC ToolCall dispatch. *)

val reduce : actor:string option -> auth_token:string option -> string -> string
