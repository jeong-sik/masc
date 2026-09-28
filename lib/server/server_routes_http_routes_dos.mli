(** Server_routes_http_routes_dos — a person's moves on the shared DOS machine
    (RFC play-link-for-the-shared-machine §2.5).

    [POST /api/v1/dos/press], [/type], [/step] and [/pass] run the tool of the
    same name under the actor [with_tool_actor_auth] resolves, after checking
    the body against that tool's schema. A body the schema refuses is a 400
    naming the field, and nothing runs. The answer is [{ok, message, data}],
    200 when the tool succeeded and 400 when it refused. Every call that ran
    wakes the Lane instances bound to the DOS machine once. *)

val press_into :
  config:Workspace.config ->
  who:string ->
  saves_name:string ->
  keys:string list ->
  [> `OK | `Bad_request ] * Yojson.Safe.t
(** [POST /api/v1/dos/press] for a caller that chose [keys] from the layout
    of the program kept under [saves_name]: the same release, answer and
    wake, and the keys go in only while that program is loaded
    ({!Dos_lane.press_into}). Another program loaded by then is a 400 and
    nothing is pressed. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
