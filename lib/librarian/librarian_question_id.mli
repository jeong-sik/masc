(** The two halves a question carries and its answer writes back
    (RFC librarian-call-only-proposes §6.1).

    A question's first line carries [front] and its last line carries [back].
    A slot that cuts the head or the tail of its input cannot write back the
    half it never saw, so the answer is thrown away as an echo mismatch. *)

type t = private
  { front : string
  ; back : string
  }

(** Length of one half: half of a SHA-256 in lowercase hexadecimal. *)
val half_length : int

(** [None] unless both halves are exactly {!half_length} lowercase
    hexadecimal characters. *)
val of_halves : front:string -> back:string -> t option

val equal : t -> t -> bool
