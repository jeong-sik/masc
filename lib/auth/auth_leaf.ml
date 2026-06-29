(** Re-export surface for the parent [Masc.Auth] facade.

    The leaf library owns the implementation in [Auth]. The parent [masc]
    library cannot refer to that module as [Auth] from inside its own
    [Auth] facade, so it depends on this distinct module name instead. *)

include Auth
