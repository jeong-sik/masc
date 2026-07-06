val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Cross-subsystem keeper waiting/deferred read model for dashboard tools.
    This module is server-owned: it may join MASC stores, but it does not add a
    dashboard dependency to lower keeper/runtime libraries. *)
