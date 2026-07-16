(** Re-export surface for the parent [Masc.Silent_dashboard_actor_outcome]
    facade.

    The leaf library owns the implementation in
    [Silent_dashboard_actor_outcome]. The parent [masc] library cannot refer
    to that module under the same name from inside its own facade, so it
    depends on this distinct module name instead. *)

include Silent_dashboard_actor_outcome
