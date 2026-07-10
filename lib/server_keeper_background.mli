val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Read model for the dashboard "Keeper autonomous background" surface.

    Projects the one piece of keeper-native autonomous work that no other
    dashboard surface exposes: per-keeper recurring tasks ({!Keeper_recurring})
    with the owning keeper's loop liveness ({!Keeper_registry}) as context.

    It deliberately does NOT re-project background-shell / fusion / HITL deferred
    work — that is already served by {!Server_keeper_waiting_inventory} and the
    dashboard reuses it there rather than duplicating the projection here. *)
