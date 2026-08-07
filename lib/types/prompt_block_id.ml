type t =
  | Keeper_instructions
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall
  | Operator_note

let equal a b =
  match a, b with
  | Keeper_instructions, Keeper_instructions
  | Dynamic_context, Dynamic_context
  | Temporal_summary, Temporal_summary
  | Memory_os_recall, Memory_os_recall
  | Operator_note, Operator_note -> true
  | ( Keeper_instructions | Dynamic_context | Temporal_summary | Memory_os_recall
    | Operator_note )
  , _ -> false

let to_string = function
  | Keeper_instructions -> "keeper_instructions"
  | Dynamic_context -> "dynamic_context"
  | Temporal_summary -> "temporal_summary"
  | Memory_os_recall -> "memory_os_recall"
  | Operator_note -> "operator_note"

let of_string = function
  | "keeper_instructions" -> Ok Keeper_instructions
  | "dynamic_context" -> Ok Dynamic_context
  | "temporal_summary" -> Ok Temporal_summary
  | "memory_os_recall" -> Ok Memory_os_recall
  | "operator_note" -> Ok Operator_note
  | name -> Error (Printf.sprintf "unknown prompt block id %S" name)

let all_known =
  [ Keeper_instructions; Dynamic_context; Temporal_summary; Memory_os_recall; Operator_note ]
;;
