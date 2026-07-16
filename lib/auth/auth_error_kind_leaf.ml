(** Re-export surface for the parent [Masc.Auth_error_kind] facade.

    The leaf library owns the implementation in [Auth_error_kind]. The parent
    [masc] library cannot refer to that module as [Auth_error_kind] from
    inside its own [Auth_error_kind] facade, so it depends on this distinct
    module name instead. *)

include Auth_error_kind
