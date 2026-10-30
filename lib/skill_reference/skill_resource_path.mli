(** Canonical path of one file bundled below an Agent Skill root. *)

type t = private string list

type error =
  | Empty
  | Absolute
  | Contains_nul
  | Contains_backslash
  | Empty_segment
  | Current_directory_segment
  | Parent_directory_segment

val of_string : string -> (t, error) result
val to_string : t -> string
val append_to : root:string -> t -> string
val error_to_string : error -> string
