(** What Candle buys: the portrait accessories that have something on them.

    One constructor per item a keeper can own. The five slots are the
    portrait's ([face], [neck], [head], [hand], [base]). An empty slot is not an
    item, so it cannot be bought. [Default] is how a keeper goes back to the
    accessory its name gives it. *)

type slot =
  | Face
  | Neck
  | Head
  | Hand
  | Base

type t =
  | Glasses
  | Shades
  | Eye_patch
  | Plaster
  | Freckles
  | Beard
  | Scarf
  | Bow_tie
  | Medal
  | Bow
  | Crown
  | Beanie
  | Book
  | Mug
  | Quill
  | Gilt_dish
  | Silver_dish
  | Oak_dish

type wear =
  | Wear of t
  | Default of slot

val all : t list
val slots : slot list
val slot : t -> slot
val slot_to_wire : slot -> string
val slot_of_wire : string -> slot option
val slot_equal : slot -> slot -> bool
val to_wire : t -> string
val of_wire : string -> t option
val equal : t -> t -> bool
val compare : t -> t -> int
val wear_slot : wear -> slot
