(** Server IDE HTTP — REST endpoints for the IDE plane.

    Routes:
    - GET  /api/v1/ide/file-activity
    - GET  /api/v1/ide/events
    - GET  /api/v1/ide/presence

    [events] uses the canonical codebase scope. [file-activity] is not the
    removed region observation store: it resolves a supplied registered
    repository id, or an exact project-base checkout match, then filters the
    durable Keeper tool-call log by that repository address. *)

module Http = Http_server_eio

val add_routes : Http.Router.t -> Http.Router.t
