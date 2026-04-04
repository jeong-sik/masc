(** Keeper_contract — typed keeper coordination/runtime enums while preserving
    current JSON and MCP string representations at the boundary. *)

type scope_kind =
  | Local
  | Global

type room_scope =
  | Current
  | All

let scope_kind_of_string = function
  | "global" -> Global
  | _ -> Local

let parse_scope_kind = function
  | "local" -> Some Local
  | "global" -> Some Global
  | _ -> None

let scope_kind_to_string = function
  | Local -> "local"
  | Global -> "global"

let room_scope_of_string = function
  | _ -> Current

let parse_room_scope = function
  | "current" | "all" -> Some Current
  | _ -> None

let room_scope_to_string = function
  | Current | All -> "current"
