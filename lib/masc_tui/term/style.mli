(** Cell visual style: foreground, background, packed attributes, and optional
    frame-local OSC 8 hyperlink identifier ([0] = none). *)

type t = {
  fg : Color.t;
  bg : Color.t;
  attrs : Attr.t;
  hyperlink_id : int;
}

val default : t

val make :
  ?fg:Color.t ->
  ?bg:Color.t ->
  ?attrs:Attr.t ->
  ?hyperlink_id:int ->
  unit ->
  t

val with_fg : Color.t -> t -> t
val with_bg : Color.t -> t -> t
val with_attrs : Attr.t -> t -> t
val add_attr : Attr.t -> t -> t
val with_hyperlink : int -> t -> t
val equal : t -> t -> bool
