(** A captured Board blob, independent of list cursors and report revisions.
    Format is an operator-selected interpretation, never inferred MIME. *)
type key = { post_id : string; sha256 : string; bytes : int; name : string option }
type presentation = Source | Markdown | Html
type content_kind = Document | Image_bytes
type content
type t
type request
type preparation_request
val request_job : request -> unit ref
val preparation_job : preparation_request -> unit ref
(** Each physical request owns one stable workspace observation key. Read and
    preparation keys are separate; closing and reopening allocates new keys.
    Dispatch and cancellation must use the key of the same original request. *)
val initial : t
val key : t -> key option
val equal_key : key -> key -> bool
val offer_image : key:key -> message:string -> t -> t
(** Keep the image's original reference without fetching. The operator may
    explicitly read it and save the verified bytes. *)
val open_read : ?content_kind:content_kind -> key:key -> t -> t * request option
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
val search_key : width:int -> height:int -> key:string -> t -> t option
val search_insert : width:int -> height:int -> text:string -> t -> t
val source : t -> (string, string) result
(** Exact original UTF-8 bytes for explicit copy; binary content is refused. *)
val saved_source : t -> (request * key * string) option
(** Original verified bytes, including binary, for an explicit save. *)
val begin_original_open : t -> t * (unit ref * request * key * string) option
(** Admit one original-image open through its final receipt. *)
val owns_original_open : t -> request -> unit ref -> bool
val withdraw_original_open : t -> t
(** Retire a not-yet-started opener or retry without asserting that an
    already-started external process was stopped. *)
val finish_original_open : t -> request -> unit ref -> t
(** A stale request or attempt cannot release the current opening. *)
val owns : t -> request -> bool
