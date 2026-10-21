(** A captured Board blob, independent of list cursors and report revisions.
    Format is an operator-selected interpretation, never inferred MIME. *)
type key = { post_id : string; sha256 : string; bytes : int; name : string option }
type presentation = Source | Markdown | Html
type content
type t
type request = key Masc_tui_fetched.request
type preparation_request
val initial : t
val key : t -> key option
val equal_key : key -> key -> bool
val open_read : key:key -> t -> t * request option
val close : t -> t
val pending : t -> request option
val pending_preparation : t -> preparation_request option
val validate : key -> string -> (content, string) result
(** Verify exact byte length and digest before admitting content. *)
val complete : t -> request -> (content, string) result -> t
val select : presentation -> t -> t
val start_preparation : width:int -> t -> t * preparation_request option
val prepare : preparation_request -> Masc_tui_detail_reading.row list
val complete_preparation : t -> preparation_request -> (Masc_tui_detail_reading.row list, string) result -> t
val document : t -> Masc_tui_detail_reading.t
val move : count:int -> height:int -> Masc_tui_detail_reading.movement -> t -> t
val source : t -> (string, string) result
(** Exact original UTF-8 bytes for explicit copy; binary content is refused. *)
val saved_source : t -> (request * key * string) option
(** Original verified bytes, including binary, for an explicit save. *)
val owns : t -> request -> bool
