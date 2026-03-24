(** Keeper_contract — typed keeper policy/runtime enums while preserving
    current JSON and MCP string representations at the boundary.

    policy_mode was removed: all keepers use a unified mode.
    Fields kept in JSON for backward compatibility. *)

type policy_action_budget =
  | Conversation
  | Board

type scope_kind =
  | Local
  | Global

type room_scope =
  | Current
  | All

type trigger_mode =
  | Explicit_only

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
  | "all" -> Current
  | _ -> Current

let parse_room_scope = function
  | "current" -> Some Current
  | "all" -> Some Current
  | _ -> None

let room_scope_to_string = function
  | Current -> "current"
  | All -> "all"

let trigger_mode_of_string = function
  | "explicit_only" -> Explicit_only
  | _ -> Explicit_only

let parse_trigger_mode = function
  | "explicit_only" -> Some Explicit_only
  | _ -> None

let trigger_mode_to_string = function
  | Explicit_only -> "explicit_only"

let trigger_mode_is_explicit_only _ = true
