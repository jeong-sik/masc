type t =
  | Keeper_instructions
  | Dynamic_context
  | Temporal_summary
  | Memory_os_recall
  | Operator_note
  | Skill_compositions

let equal a b =
  match a, b with
  | Keeper_instructions, Keeper_instructions
  | Dynamic_context, Dynamic_context
  | Temporal_summary, Temporal_summary
  | Memory_os_recall, Memory_os_recall
  | Operator_note, Operator_note
  | Skill_compositions, Skill_compositions -> true
  | ( Keeper_instructions | Dynamic_context | Temporal_summary | Memory_os_recall
    | Operator_note | Skill_compositions )
  , _ -> false

let to_string = function
  | Keeper_instructions -> "keeper_instructions"
  | Dynamic_context -> "dynamic_context"
  | Temporal_summary -> "temporal_summary"
  | Memory_os_recall -> "memory_os_recall"
  | Operator_note -> "operator_note"
  | Skill_compositions -> "skill_compositions"

let of_string = function
  | "keeper_instructions" -> Ok Keeper_instructions
  | "dynamic_context" -> Ok Dynamic_context
  | "temporal_summary" -> Ok Temporal_summary
  | "memory_os_recall" -> Ok Memory_os_recall
  | "operator_note" -> Ok Operator_note
  | "skill_compositions" -> Ok Skill_compositions
  | name -> Error (Printf.sprintf "unknown prompt block id %S" name)

let all_known =
  [ Keeper_instructions
  ; Dynamic_context
  ; Temporal_summary
  ; Memory_os_recall
  ; Operator_note
  ; Skill_compositions
  ]
;;

(* See the mli. Ordered by how often each block's content actually changed,
   not by what it holds: the 51 KB memory block moved 65 times in 386 turns
   while the 81 B clock line moved 306, and the clock was in front of it. *)
let cache_rank = function
  | Keeper_instructions -> 0
  | Skill_compositions -> 1
  | Memory_os_recall -> 2
  | Dynamic_context -> 3
  | Temporal_summary -> 4
  (* An operator speaking mid-turn is the newest thing in the assembly and the
     only block that rides a post-tool round; it stays last on both counts. *)
  | Operator_note -> 5
;;

(* See the mli. [Keeper_instructions] never enters the extra-context
   assembly (it is the rendered system prompt, recorded separately for the
   TurnRecord); it answers [true] because it is not a recurring world-state
   re-broadcast, and the exhaustive match keeps a new constructor from
   inheriting either class silently. *)
let injected_on_post_tool_round = function
  | Dynamic_context | Temporal_summary | Memory_os_recall | Skill_compositions -> false
  | Keeper_instructions | Operator_note -> true
;;
