(** Source-pixel zoom and pan over the original encoded image. *)
type t
type action = Zoom_in | Zoom_out | Fit | Left | Right | Up | Down
type window = { x : int; y : int; width : int; height : int;
  columns : int; rows : int }
val create : width:int -> height:int -> t option
(** [None] for nonpositive image dimensions. *)
val window : cell_pixels:(int * int) -> columns:int -> rows:int -> t -> window
val apply : cell_pixels:(int * int) -> columns:int -> rows:int -> action -> t -> t
(** Pan by one visible cell; zoom around the same source point. Bounds derive
    from the original image and at least one source pixel remains visible. *)
val zoom : t -> float
