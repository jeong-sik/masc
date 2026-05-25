(** Option → JSON small builders + git_upstream_status record +
    2 small utility helpers for the dashboard runtime-info surface. *)


val opt_string_json : string option -> Yojson.Safe.t
val opt_bool_json : bool option -> Yojson.Safe.t
val opt_int_json : int option -> Yojson.Safe.t
val opt_commit_equal : string option -> string option -> bool option

type git_upstream_status =
  { branch : string option
  ; upstream_ref : string option
  ; upstream_head_commit : string option
  ; ahead_count : int option
  ; behind_count : int option
  }

val empty_git_upstream_status : git_upstream_status
