(** Tool_name_alias_axis -- low-dependency public alias projection.

    This module intentionally stays string-only so lower libraries such as
    [masc_workspace] can canonicalize public model aliases without depending on
    keeper runtime modules. *)

type public_alias =
  { public_name : string
  ; internal_name : string
  }

type public_tool =
  | Execute
  | Edit
  | Web_fetch
  | Read
  | Grep
  | Web_search
  | Write

val public_aliases : public_alias list
val all : public_tool list
val preferred_name : public_tool -> string
val internal_name : public_tool -> string
val compatibility_names : public_tool -> string list
val public_tool_of_name : string -> public_tool option
val public_names : unit -> string list
val internal_name_of_public : string -> string option
val public_name_for_internal : string -> string option
val strip_mcp_masc_prefix : string -> string
