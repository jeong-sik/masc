(** An immutable, read-only document for a selected object's complete details.
    The surface owns freshness and selection; this reader never follows a
    changing cursor, refreshes data, or authorizes an action. *)

type section = { heading : string; body : string }
type t
type row = Heading of string | Content of string | Note of string
type movement = First | Last | By of int

val create : title:string -> section list -> t
val create_observation : title:string -> section list -> t
(** Source-owned observation documents use their own refresh controls and
    lifecycle notes; they do not show the captured-document reopen hint. *)
val replace : title:string -> section list -> t -> t
(** Replace the same source observation while retaining its independent scroll intent. *)
val title : t -> string
val replace_prepared : title:string -> hints:string -> width:int -> row list -> t -> t
(** Already sanitized, complete rows prepared away from the UI thread.
    Rows are usable only at their original width. Replacement retains scroll.
    The caller owns preparation/source identity and re-prepares on resize. *)
val hints : t -> string option
val rows : width:int -> t -> row list
val scroll : count:int -> height:int -> t -> int
val move : count:int -> height:int -> movement -> t -> t
(** [Last] retains an end anchor across reflow and replacement of the same
    captured observation, including temporary preparation rows. [First] starts
    at zero. [By] leaves the anchor and moves from the current bounded position.
    A newly created reading always starts at zero. *)
