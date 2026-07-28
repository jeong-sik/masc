(** Keeper-owned provider tool-choice admission. *)

type rejection =
  | Forced_any
  | Forced_named of string

let rejection_to_string = function
  | Forced_any ->
    "Keeper runtimes do not admit tool_choice=any; use auto, none, or omit it"
  | Forced_named name ->
    Printf.sprintf
      "Keeper runtimes do not admit forced named tool_choice=%S; use auto, none, \
       or omit it"
      name
;;

let validate_for_keeper = function
  | Some Agent_sdk.Types.Any -> Error Forced_any
  | Some (Agent_sdk.Types.Tool name) -> Error (Forced_named name)
  | other -> Ok other
;;
