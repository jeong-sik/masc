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

val resources_list_request_body : ?cursor:string -> request_id:string -> unit -> string
(** The [resources/list] request. [cursor] asks for the page that follows the
    one a previous answer returned. *)

val resources_read_request_body : request_id:string -> uri:string -> string
(** The [resources/read] request for one resource. *)

type resource = {
  uri : string;
  name : string;
  title : string option;
  description : string option;
  mime_type : string option;
  size : int option;
}
(** Metadata advertised by [resources/list]. Optional fields remain optional:
    absence is different from an empty value supplied by the server. *)

val display_name : resource -> string
(** The name a reader sees in the list: the server's [title] when it sent a
    non-blank one, otherwise the [name]. Beside the type because two readers
    need the same answer -- the list draws it and the row search matches on
    it, and a search that matches text the list does not show finds rows the
    reader cannot see. *)

type resources_walk_stop =
  [ `Complete
  | `Page_limit_reached of int
  | `Repeated_cursor of string
  ]
(** How a [resources_list_all] walk ended. *)

val resources_of_body :
  request_id:string -> string -> (resource list, string) result
(** Read one [resources/list] answer in server order without discarding the
    fields that explain what each resource contains. This is the first page
    only; a caller that can lose the rest must use [resources_page_of_body]
    or [resources_list_all]. *)

val resources_page_of_body :
  request_id:string -> string -> (resource list * string option, string) result
(** One [resources/list] answer as its page and the cursor for the next one,
    [None] when this was the last page. *)

val resources_list_all :
  request_id:string ->
  ?max_pages:int ->
  fetch:(cursor:string option -> (string, string) result) ->
  unit ->
  (resource list * resources_walk_stop, string) result
(** Every page, in server order, by calling [fetch] once per page until the
    answer carries no [nextCursor]. The returned stop says how the walk ended:
    [`Complete] means the listing is whole, [`Repeated_cursor] and
    [`Page_limit_reached] mean it is not, and a caller must surface that rather
    than present the pages it got as the whole listing. A cursor already seen
    ends the walk, and [max_pages] (64 by default) bounds a server that keeps
    returning fresh cursors. [Error] is the first [fetch] or parse failure. *)

type resource_content_kind =
  | Resource_text of string
  | Resource_blob of { base64 : string }

type resource_content = {
  rc_uri : string option;
  rc_mime_type : string option;
  rc_kind : resource_content_kind;
}
(** One content part from [resources/read]. Keep the original encoded blob;
    decoding and image conversion belong to an explicitly requested preview. *)

val resource_contents_of_body :
  request_id:string -> string -> (resource_content list, string) result
(** Read every [resources/read] content part without discarding its MIME type. *)
