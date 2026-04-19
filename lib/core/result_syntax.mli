(** Result_syntax — thin re-export of stdlib [Stdlib.Result.Syntax].

    Kept as a compatibility alias; prefer [open Result.Syntax] at call sites. *)

include module type of Stdlib.Result.Syntax
