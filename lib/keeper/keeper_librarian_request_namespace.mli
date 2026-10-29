(** Which kind of original a Librarian request ID names. The host's Exact
    authorization and the wake discovery classify every request they see with
    this one function, so a new kind of original is a compile error in both
    rather than a request one of them silently treats as foreign. *)
type t =
  | Admission of string
  | History of string
  | Floor_step of string
  | Other
(** The string is the store scope the ID's own decoder derives. An ID no decoder
    accepts is [Other]. The kinds do not overlap: each ID format has its own tag. *)
val of_request_id : string -> t
