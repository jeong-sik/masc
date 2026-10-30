type t =
  | Keeper_instructions
  | Dynamic_context
  | Active_goals
  | Completion_authority
  | Admitted_scheduled_input
  | Temporal_summary
  | Memory_os_recall
  | Librarian_working_context
  | Recalled_memory
  | Recalled_memory_status
  | Operator_note
  | Skill_compositions
[@@deriving enumerate]

let equal a b =
  match a, b with
  | Keeper_instructions, Keeper_instructions
  | Dynamic_context, Dynamic_context
  | Active_goals, Active_goals
  | Completion_authority, Completion_authority
  | Admitted_scheduled_input, Admitted_scheduled_input
  | Temporal_summary, Temporal_summary
  | Librarian_working_context, Librarian_working_context
  | Memory_os_recall, Memory_os_recall
  | Recalled_memory, Recalled_memory
  | Recalled_memory_status, Recalled_memory_status
  | Operator_note, Operator_note
  | Skill_compositions, Skill_compositions -> true
  | ( Keeper_instructions | Dynamic_context | Active_goals | Completion_authority | Admitted_scheduled_input | Temporal_summary | Memory_os_recall
    | Librarian_working_context | Recalled_memory | Recalled_memory_status | Operator_note | Skill_compositions )
  , _ -> false

let to_string = function
  | Keeper_instructions -> "keeper_instructions"
  | Dynamic_context -> "dynamic_context"
  | Active_goals -> "active_goals"
  | Admitted_scheduled_input -> "admitted_scheduled_input"
  | Completion_authority -> "completion_authority"
  | Temporal_summary -> "temporal_summary"
  | Memory_os_recall -> "memory_os_recall"
  | Librarian_working_context -> "librarian_working_context"
  | Recalled_memory -> "recalled_memory"
  | Recalled_memory_status -> "recalled_memory_status"
  | Operator_note -> "operator_note"
  | Skill_compositions -> "skill_compositions"

let of_string name =
  match List.find_opt (fun v -> String.equal (to_string v) name) all with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "unknown prompt block id %S" name)

let all_known =
  [ Keeper_instructions
  ; Dynamic_context
  ; Active_goals
  ; Completion_authority
  ; Admitted_scheduled_input
  ; Temporal_summary
  ; Memory_os_recall
  ; Librarian_working_context
  ; Recalled_memory
  ; Recalled_memory_status
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
  (* The split retains their prior assembly position: ordinary facts first,
     then the independently versioned Librarian index. *)
  | Memory_os_recall -> 2
  | Librarian_working_context -> 3
  | Active_goals -> 4
  | Completion_authority -> 5
  | Admitted_scheduled_input -> 6
  (* The two recall blocks are placed before their first measurement (RFC
     keeper-recall-reaches-the-turn, section 4.4). The body changes only when
     the set of carried memories does, so it is in front of the context that
     changes on nearly every turn. The status line names the turn, so it
     changes every turn and sits behind that context and in front of the
     clock. The canary measures how often each really changes. *)
  | Recalled_memory -> 7
  | Dynamic_context -> 8
  | Recalled_memory_status -> 9
  | Temporal_summary -> 10
  (* An operator speaking mid-turn is the newest thing in the assembly and the
     newest instruction in a post-tool round; it stays last on both counts. *)
  | Operator_note -> 11
;;

(* See the mli. [Keeper_instructions] never enters the extra-context
   assembly (it is the rendered system prompt, recorded separately for the
   TurnRecord); it answers [true] because it is not a recurring world-state
   re-broadcast, and the exhaustive match keeps a new constructor from
   inheriting either class silently. *)
let injected_on_post_tool_round = function
  | Dynamic_context | Temporal_summary | Memory_os_recall | Librarian_working_context
  | Recalled_memory | Recalled_memory_status | Skill_compositions -> false
  | Keeper_instructions | Active_goals | Completion_authority | Admitted_scheduled_input | Operator_note -> true
;;

(* See the mli. [Keeper_instructions] never enters the extra-context assembly
   a resume carries; it answers [false] because a resumed session already holds
   the system prompt it recorded at its first launch. *)
let resent_when_held = function
  | Keeper_instructions | Dynamic_context | Active_goals | Temporal_summary | Memory_os_recall
  | Librarian_working_context | Recalled_memory | Skill_compositions -> false
  | Completion_authority | Admitted_scheduled_input | Recalled_memory_status | Operator_note -> true
;;
