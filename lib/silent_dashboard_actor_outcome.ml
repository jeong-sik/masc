(** Compatibility facade for [Masc.Silent_dashboard_actor_outcome].

    The implementation lives in the leaf [masc.auth] library.  Keep this
    module as a thin re-export so the parent [masc] library does not carry a
    second outcome implementation that can drift from the leaf SSOT. *)

include Silent_dashboard_actor_outcome_leaf
