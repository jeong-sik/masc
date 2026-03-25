(** Keeper_contract — typed keeper coordination/runtime enums while preserving
    current JSON and MCP string representations at the boundary. *)

type policy_action_budget =
  | Conversation
  | Board

type scope_kind =
  | Local
  | Global

type room_scope =
  | Current
  | All

let policy_action_budget_of_string = function
  | "board" -> Board
  | _ -> Conversation

let parse_policy_action_budget = function
  | "conversation" -> Some Conversation
  | "board" -> Some Board
  | _ -> None

let policy_action_budget_to_string = function
  | Conversation -> "conversation"
  | Board -> "board"

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
  | "all" -> All
  | _ -> Current

let parse_room_scope = function
  | "current" -> Some Current
  | "all" -> Some All
  | _ -> None

let room_scope_to_string = function
  | Current -> "current"
  | All -> "all"
