(** Result_syntax — shared Result monad binding operators.

    Eliminates the need for per-file Result.bind definitions
    that were duplicated across 21+ files.
    Usage: [open Result_syntax] at the top of any module that
    uses [let*] for Result chaining. *)

let ( let* ) = Result.bind
let ( let+ ) r f = Result.map f r
