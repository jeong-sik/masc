val json :
  ?actor:string ->
  ?session_id:string ->
  ?operation_id:string ->
  config:Room.config ->
  unit ->
  Yojson.Safe.t
