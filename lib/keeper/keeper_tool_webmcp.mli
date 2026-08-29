(** Keeper WebMCP consumer tools (RFC-webmcp-keeper-consumption Lane B).

    [keeper_webmcp_list] and [keeper_webmcp_call] relay to the embedded node
    bridge (see [Webmcp_bridge]) against an operator-run headed Chrome. Every
    missing prerequisite is a typed refusal; there is no retry and no
    fallback. *)

val list_tool_name : string
val call_tool_name : string

val dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result option
(** [None] when [name] is neither webmcp tool. *)
