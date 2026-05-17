(** Server_mcp_streaming_tools — auto-upgrade dispatch registry for
    POST /mcp [tools/call] requests.

    See implementation for the policy that governs membership. *)

val streaming_capable_tools : string list
(** The full registry as an ordered list, for diagnostics and tests. *)

val is_streaming_capable : string -> bool
(** [is_streaming_capable name] is [true] when [POST /mcp] dispatch should
    upgrade to SSE framing for [tools/call] with [name]. Lookup is a single
    hashtable probe over {!streaming_capable_tools}. *)
