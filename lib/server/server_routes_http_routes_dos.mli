(** Server_routes_http_routes_dos — a person's moves on the shared DOS machine
    (RFC play-link-for-the-shared-machine §2.5).

    [POST /api/v1/dos/press], [/type], [/step] and [/pass] run the tool of the
    same name under the actor [with_tool_actor_auth] resolves, after checking
    the body against that tool's schema. A body the schema refuses is a 400
    naming the field, and nothing runs. The answer is [{ok, message, data}],
    200 when the tool succeeded and 400 when it refused. Every call that ran
    wakes the Lane instances bound to the DOS machine once. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
