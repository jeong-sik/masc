(** See [keeper_chat_role.mli] for the contract. *)

type t = User | Assistant

let of_string s =
  let trimmed = String.trim s in
  let lower = String.lowercase_ascii trimmed in
  match lower with
  | "user" -> Ok User
  | "assistant" -> Ok Assistant
  | other -> Error (`Msg (Printf.sprintf "invalid role: %S (expected user|assistant)" other))
;;

let to_string = function
  | User -> "user"
  | Assistant -> "assistant"
;;

let to_yojson t = `String (to_string t)

let of_yojson json =
  match json with
  | `String s -> of_string s
  | other -> Error (`Msg (Printf.sprintf "expected string for role, got %s" (Yojson.Safe.to_string other)))
;;