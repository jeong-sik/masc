(** Wiki page names. Pure: no file is read or written here. *)

type page_name_error =
  | Empty_page_name
  | Bad_page_characters
  | Dash_at_edge
  | Reserved_page_name

val reserved_page_names : string list
(** The names the wiki keeps for its own files: [index] and [log]. *)

val validate_page_name : string -> (string, page_name_error) result
(** Whether [raw] can serve as a page topic: lowercase letters, digits and
    inner dashes only, and not one of {!reserved_page_names}. A name that
    breaks the rule is refused, not repaired. *)

val page_name_error_to_string : string -> page_name_error -> string
(** [page_name_error_to_string raw error] names [raw] as written. *)
