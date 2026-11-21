type verdict =
  | Ask of { because : string }
  | Run

val verdict_for
  :  identity_tool_index:Keeper_identity_tool_index.t
  -> tool_name:string
  -> input:Yojson.Safe.t
  -> verdict

val classifies
  :  identity_tool_index:Keeper_identity_tool_index.t
  -> tool_name:string
  -> bool

val question_for : tool_name:string -> input:Yojson.Safe.t -> string
