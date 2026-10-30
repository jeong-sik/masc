(** Result monadic binding operators for the llm_provider library.

    Centralized definitions for {!Result} binding operators used across
    llm_provider. Open this module in files that use [let*] and [let+]
    for Result-based computation chains.

    @since 0.208.0 *)

let ( let* ) = Result.bind
let ( let+ ) x f = Result.map f x

let both a b =
  match a, b with
  | Ok a_val, Ok b_val -> Ok (a_val, b_val)
  | Error e, _ -> Error e
  | _, Error e -> Error e
;;

let ( and* ) = both
let ( and+ ) = both
