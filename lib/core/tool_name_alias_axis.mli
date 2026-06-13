(** Tool_name_alias_axis -- low-dependency public alias projection.

    This module intentionally stays string-only so lower libraries such as
    [masc_workspace] can canonicalize public model aliases without depending on
    keeper runtime modules. *)

type public_alias =
  { public_name : string
  ; internal_name : string
  }

val public_aliases : public_alias list
val public_names : unit -> string list
val internal_name_of_public : string -> string option
val public_name_for_internal : string -> string option
val strip_mcp_masc_prefix : string -> string
