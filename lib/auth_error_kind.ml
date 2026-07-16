(** Compatibility facade for [Masc.Auth_error_kind].

    The implementation lives in the leaf [masc.auth] library.  Keep this
    module as a thin re-export so the parent [masc] library does not carry a
    second error-classification implementation that can drift from the leaf
    SSOT. *)

include Auth_error_kind_leaf
