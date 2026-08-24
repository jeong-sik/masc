(** One MCP [tools/call] over the transport's HTTP endpoint, as the TUI
    speaks it: the JSON-RPC request body and the reading of the answer.

    The server answers a [POST /mcp] with the JSON-RPC response framed as a
    server-sent event stream - one [data:] line carrying the whole response
    object - or, for some errors, as a plain JSON object. Both are read
    here. Nothing performs I/O; the transport sends the body and hands back
    what came over the wire.

    The task tools the dashboard calls this way ([masc_add_task],
    [masc_transition]) have no REST route of their own, so this is the one
    path by which the TUI can create work for a keeper. *)

val request_body :
  request_id:string -> tool:string -> arguments:(string * Yojson.Safe.t) list -> string
(** The [tools/call] request. [request_id] is the JSON-RPC id the answer
    carries back, so a caller can tell an answer from a stale one. *)

(** What the tool answered. A tool that ran and reported a failure comes
    back [is_error = true] with the server's text; that is the tool's verdict,
    not a transport failure. *)
type outcome = {
  text : string;  (** The concatenated text parts of [result.content]. *)
  is_error : bool;
}

val outcome_of_body : request_id:string -> string -> (outcome, string) result
(** Read the HTTP body of a [tools/call]. [Error] names a body this cannot
    read: no [data:] line and no JSON object, a JSON-RPC [error] member, an
    answer to a different id, or a result with no text content. *)

val task_id_of_add_task : string -> (string, string) result
(** The id of the task [masc_add_task] created, read from its text answer,
    which is a JSON object carrying [task_id]. [Error] for any other
    shape, with the text the tool did return. *)
