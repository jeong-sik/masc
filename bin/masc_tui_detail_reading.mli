(** An immutable, read-only capture of a selected object's complete details.
    The surface owns freshness and selection; this reader never follows a
    changing cursor, refreshes data, or authorizes an action. *)

type section = { heading : string; body : string }
type t
type row = Heading of string | Content of string | Note of string
type movement = First | Last | By of int

val create : title:string -> section list -> t
val replace : title:string -> section list -> t -> t
(** Replace the same source observation while retaining its independent scroll intent. *)
val title : t -> string
val rows : width:int -> t -> row list
val scroll : count:int -> height:int -> t -> int
val move : count:int -> height:int -> movement -> t -> t
