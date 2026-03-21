(** Keeper_contract — typed keeper policy/runtime enums while preserving
    current JSON and MCP string representations at the boundary. *)

type policy_mode =
  | Heuristic
  | Learned_offline_v1
  | Explicit_event_v1
  | Model_deliberation

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
  | Legacy
  | Explicit_only

let policy_mode_of_string = function
  | "learned_offline_v1" -> Learned_offline_v1
  | "explicit_event_v1" -> Explicit_event_v1
  | "model_deliberation" -> Model_deliberation
  | _ -> Heuristic

let parse_policy_mode = function
  | "heuristic" -> Some Heuristic
  | "learned_offline_v1" -> Some Learned_offline_v1
  | "explicit_event_v1" -> Some Explicit_event_v1
  | "model_deliberation" -> Some Model_deliberation
  | _ -> None

let policy_mode_to_string = function
  | Heuristic -> "heuristic"
  | Learned_offline_v1 -> "learned_offline_v1"
  | Explicit_event_v1 -> "explicit_event_v1"
  | Model_deliberation -> "model_deliberation"

let policy_mode_is_learned = function
  | Learned_offline_v1 -> true
  | Heuristic | Explicit_event_v1 | Model_deliberation -> false

let policy_mode_is_deliberation = function
  | Model_deliberation -> true
  | Heuristic | Learned_offline_v1 | Explicit_event_v1 -> false

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

let trigger_mode_of_string = function
  | "explicit_only" -> Explicit_only
  | _ -> Legacy

let parse_trigger_mode = function
  | "legacy" -> Some Legacy
  | "explicit_only" -> Some Explicit_only
  | _ -> None

let trigger_mode_to_string = function
  | Legacy -> "legacy"
  | Explicit_only -> "explicit_only"

let trigger_mode_is_explicit_only = function
  | Explicit_only -> true
  | Legacy -> false

(** Parse autonomy_level is now a no-op: returns the string as-is for backward compat. *)
let parse_autonomy_level (raw : string) : string option =
  let s = String.lowercase_ascii (String.trim raw) in
  if s = "" then None else Some s

(** Store autonomy_level as lowercase string for backward compat. *)
let autonomy_level_to_storage_string (level : string) : string =
  String.lowercase_ascii (String.trim level)
