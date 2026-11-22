(** Packed SGR text attribute bitflags.

    SGR dim ([CSI 2m]) is intentionally omitted per the >= 4.5:1 Oklab contrast
    invariant: low-emphasis hierarchy uses explicit foreground colors instead. *)

type t = private int

val none : t
val bold : t
val italic : t
val underline : t
val reverse : t
val strike : t

val ( lor ) : t -> t -> t
val union : t -> t -> t
val remove : t -> t -> t
val has : t -> t -> bool
val equal : t -> t -> bool
val to_bits : t -> int
