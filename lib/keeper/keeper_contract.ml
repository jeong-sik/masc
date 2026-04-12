(** Keeper_contract — typed keeper coordination/runtime enums while preserving
    current JSON and MCP string representations at the boundary. *)

type room_scope =
  | Current
  | All

let room_scope_of_string = function
  | "current" | "all" -> Current
  | _ -> Current

let parse_room_scope = function
  | "current" | "all" -> Some Current
  | _ -> None

let room_scope_to_string = function
  | Current -> "current"
  | All -> "all"
