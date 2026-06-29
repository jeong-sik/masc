(** Compatibility facade for [Masc.Auth].

    The implementation lives in the leaf [masc.auth] library.  Keep this module
    as a thin re-export so the parent [masc] library does not carry a second
    authentication implementation that can drift from the leaf SSOT. *)

include Auth_leaf
