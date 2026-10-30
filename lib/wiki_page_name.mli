(** Wiki page names. Pure: no file is read or written here. *)

type page_name_error =
  | Empty_page_name
  | Bad_page_characters
  | Dash_at_edge
  | Reserved_page_name

val index_name : string
(** ["index"]: the name of the wiki's index file, without [.md]. *)

val log_name : string
(** ["log"]: the name of the wiki's log file, without [.md]. *)

val reserved_page_names : string list
(** The names the wiki keeps for its own files: {!index_name} and
    {!log_name}. *)

val validate_page_name : string -> (string, page_name_error) result
(** Whether [raw] can serve as a page topic: lowercase letters, digits and
    inner dashes only, and not one of {!reserved_page_names}. A name that
    breaks the rule is refused, not repaired. *)

val page_name_error_to_string : string -> page_name_error -> string
(** [page_name_error_to_string raw error] names [raw] as written. *)
