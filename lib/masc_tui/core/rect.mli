(** Integer cell-space rectangle geometry for layout, clipping, and hit-maps. *)

type t = {
  x : int;
  y : int;
  w : int;
  h : int;
}

val empty : t
val make : x:int -> y:int -> w:int -> h:int -> t
(** Clamps negative [w] or [h] to [0]. *)

val right : t -> int
(** Exclusive right edge [x + w]. *)

val bottom : t -> int
(** Exclusive bottom edge [y + h]. *)

val area : t -> int
val is_empty : t -> bool
val contains : t -> x:int -> y:int -> bool
val intersect : t -> t -> t

val inset : ?top:int -> ?right:int -> ?bottom:int -> ?left:int -> t -> t
(** Shrinks [t] inward by the requested margins (negative margins clamp to [0]). *)

val inset_uniform : dx:int -> dy:int -> t -> t
val split_h : t -> left_w:int -> t * t
(** Horizontal split: left rectangle of clamped width [left_w], right remainder. *)

val split_v : t -> top_h:int -> t * t
(** Vertical split: top rectangle of clamped height [top_h], bottom remainder. *)

val equal : t -> t -> bool
