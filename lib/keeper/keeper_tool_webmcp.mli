(** Keeper WebMCP consumer tools (RFC-webmcp-keeper-consumption Lane B).

    [keeper_webmcp_list] and [keeper_webmcp_call] relay to the embedded node
    bridge (see [Webmcp_bridge]) against an operator-run headed Chrome. Every
    missing prerequisite is a typed refusal; there is no retry and no
    fallback. *)

val call_tool_name : string
(** The call tool's registry name; the in-process adapter compares against it
    to attach [Effect_outcome_unknown] to call failures only. *)

val dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result option
(** [None] when [name] is neither webmcp tool. *)
