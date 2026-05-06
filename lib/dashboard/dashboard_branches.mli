type branch_status =
  | Clean
  | Ahead
  | Behind
  | Diverged
  | Untracked

type branch_entry =
  { name : string
  ; tag : string option
  ; status : branch_status
  ; ahead : int
  ; behind : int
  ; head : string
  ; keepers : string list
  }

val parse_branch_ref_line : string -> (string * string) option
val parse_branch_refs : string -> (string * string) list
val parse_ahead_behind : string -> (int * int) option
val status_of_counts : has_upstream:bool -> ahead:int -> behind:int -> branch_status
val status_to_string : branch_status -> string
val keepers_by_branch : config:Coord.config -> (string * string list) list
val list_entries : config:Coord.config -> branch_entry list
val entry_to_json : branch_entry -> Yojson.Safe.t
val json : config:Coord.config -> Yojson.Safe.t
