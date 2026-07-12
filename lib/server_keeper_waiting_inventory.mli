val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Cross-subsystem keeper waiting/deferred read model for dashboard tools.
    This parent-library module is shared by server and tool entrypoints; it may
    join MASC stores, but it does not add a dashboard dependency to lower
    keeper/runtime libraries. *)

val tool_json : Workspace.config -> Yojson.Safe.t
(** Redacted public-tool projection. It retains lifecycle counts, receipt ids,
    and failure kinds, but omits connector route coordinates and persistence
    paths/messages that are reserved for the authenticated dashboard boundary. *)
