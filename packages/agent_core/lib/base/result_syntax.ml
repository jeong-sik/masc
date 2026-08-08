(** Result monadic binding operators.

    Centralized definitions for {!Result} binding operators used across
    the agent_sdk codebase. Open this module in files that use [let*]
    and [let+] for Result-based computation chains.

    Also provides {!Let_syntax} for [ppx_let] support ([let%bind],
    [let%map], [and%bind]).

    @since 0.187.7
    @stability Stable *)

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

(** ppx_let integration.

    After [open Result_syntax], [let%bind] and [let%map] are available
    alongside the built-in [let*] / [let+] operators. Both styles are
    equivalent; [ppx_let] provides better error messages for nested
    bindings and supports [and%bind] for parallel composition.

    {[open Result_syntax
    let compute x =
      let%bind a = parse x in
      let%bind b = validate a in
      let%map c = transform b in
      c]} *)
module Let_syntax = struct
  let return x = Ok x
  let bind t ~f = Result.bind t f
  let map t ~f = Result.map f t
  let both = both
end
