(** Operator snapshot view selector. *)

type snapshot_view =
  | Summary
  | Sessions
  | Keepers
  | Messages
  | Full

val snapshot_view_to_string : snapshot_view -> string
(** Stable wire label for a snapshot view. *)

val valid_snapshot_view_strings : string list
(** All accepted wire labels. *)

val snapshot_view_of_string_opt : string -> snapshot_view option
(** Parse a canonical view string, returning [None] for unknown inputs. *)
