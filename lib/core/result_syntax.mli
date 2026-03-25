(** Result_syntax — shared Result monad binding operators.

    Usage: [open Result_syntax] at the top of any module that
    uses [let*] for Result chaining. *)

val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
val ( let+ ) : ('a, 'e) result -> ('a -> 'b) -> ('b, 'e) result
