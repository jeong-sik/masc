type t =
  | Keeper_instructions
  | Dynamic_context
  | Active_goals
  | Direct_input_source
  | Completion_authority
  | Goals_awaiting_proof
  | Constitution_amendments
  | Temporal_summary
  | Memory_os_recall
  | Librarian_working_context
  | Recalled_memory
  | Recalled_memory_status
  | Operator_note
  | Skill_compositions
  | Arrived_stimuli
[@@deriving enumerate]

let equal a b =
  match a, b with
  | Keeper_instructions, Keeper_instructions
  | Dynamic_context, Dynamic_context
  | Active_goals, Active_goals
  | Direct_input_source, Direct_input_source
  | Completion_authority, Completion_authority
  | Goals_awaiting_proof, Goals_awaiting_proof
  | Constitution_amendments, Constitution_amendments
  | Temporal_summary, Temporal_summary
  | Librarian_working_context, Librarian_working_context
  | Memory_os_recall, Memory_os_recall
  | Recalled_memory, Recalled_memory
  | Recalled_memory_status, Recalled_memory_status
  | Operator_note, Operator_note
  | Skill_compositions, Skill_compositions
  | Arrived_stimuli, Arrived_stimuli -> true
  | ( Keeper_instructions | Dynamic_context | Active_goals | Direct_input_source | Completion_authority
    | Goals_awaiting_proof | Constitution_amendments | Temporal_summary | Memory_os_recall
    | Librarian_working_context | Recalled_memory | Recalled_memory_status | Operator_note
    | Skill_compositions | Arrived_stimuli )
  , _ -> false

let to_string = function
  | Keeper_instructions -> "keeper_instructions"
  | Dynamic_context -> "dynamic_context"
  | Active_goals -> "active_goals"
  | Direct_input_source -> "direct_input_source"
  | Completion_authority -> "completion_authority"
  | Goals_awaiting_proof -> "goals_awaiting_proof"
  | Constitution_amendments -> "constitution_amendments"
  | Temporal_summary -> "temporal_summary"
  | Memory_os_recall -> "memory_os_recall"
  | Librarian_working_context -> "librarian_working_context"
  | Recalled_memory -> "recalled_memory"
  | Recalled_memory_status -> "recalled_memory_status"
  | Operator_note -> "operator_note"
  | Skill_compositions -> "skill_compositions"
  | Arrived_stimuli -> "arrived_stimuli"

let of_string name =
  match List.find_opt (fun v -> String.equal (to_string v) name) all with
  | Some v -> Ok v
  | None -> Error (Printf.sprintf "unknown prompt block id %S" name)

let all_known =
  [ Keeper_instructions
  ; Dynamic_context
  ; Active_goals
  ; Direct_input_source
  ; Completion_authority
  ; Goals_awaiting_proof
  ; Constitution_amendments
  ; Temporal_summary
  ; Memory_os_recall
  ; Librarian_working_context
  ; Recalled_memory
  ; Recalled_memory_status
  ; Operator_note
  ; Skill_compositions
  ; Arrived_stimuli
  ]
;;

(* See the mli. Ordered by how often each block's content actually changed,
   not by what it holds: the 51 KB memory block moved 65 times in 386 turns
   while the 81 B clock line moved 306, and the clock was in front of it. *)
let cache_rank = function
  | Keeper_instructions -> 0
  | Skill_compositions -> 1
  (* RFC-0491 §3.2: the articles written or taken back since the System's
     <norms>. Its text changes only when the world's article ledger is
     written (0 to 7 times a day, 2026-10-08 to 11-05), and it leaves when the
     System is rendered again, which happens when the range front moves and
     the history cache is lost anyway. That is less often than the memory
     recall body (65 contents in 386 turns) and more often than the Skill
     compositions (1), so it sits between them, ahead of every block that
     changes on most turns. *)
  | Constitution_amendments -> 2
  (* The split retains their prior assembly position: ordinary facts first,
     then the independently versioned Librarian index. *)
  | Memory_os_recall -> 3
  | Librarian_working_context -> 4
  | Active_goals -> 5
  (* The source of the admitted direct operation is issued right behind the
     Goal snapshot (see the mli). Its bytes are the same for every request of
     one operation and change when another operation is admitted. How often
     that is has not been measured. *)
  | Direct_input_source -> 6
  (* RFC-0491 §3.3: the ids of the Goals in [Verifying]. Its text changes when
     a Goal is asked to complete or the verifier refutes the proof: after
     10-30 the two came 12 to 20 minutes apart. A Task decision is new on the
     turn it lands and gone on the next, so this block sits just in front of
     [Completion_authority]. *)
  | Goals_awaiting_proof -> 7
  | Completion_authority -> 8
  (* The two recall blocks are placed before their first measurement (RFC
     keeper-recall-reaches-the-turn, section 4.4). The body changes only when
     the set of carried memories does, so it is in front of the context that
     changes on nearly every turn. The status line names the turn, so it
     changes every turn and sits behind that context and in front of the
     clock. The canary measures how often each really changes. *)
  | Recalled_memory -> 9
  | Dynamic_context -> 10
  | Recalled_memory_status -> 11
  | Temporal_summary -> 12
  (* A queue row that arrived while the turn ran is news about the world and
     comes in front of an operator speaking, who stays the newest thing in the
     assembly and the newest instruction in a post-tool round. *)
  | Arrived_stimuli -> 13
  | Operator_note -> 14
;;

(* See the mli. [Keeper_instructions] never enters the extra-context
   assembly (it is the rendered system prompt, recorded separately for the
   TurnRecord); it answers [true] because it is not a recurring world-state
   re-broadcast, and the exhaustive match keeps a new constructor from
   inheriting either class silently. *)
let injected_on_post_tool_round = function
  | Dynamic_context | Temporal_summary | Memory_os_recall | Librarian_working_context
  | Recalled_memory | Recalled_memory_status | Skill_compositions -> false
  | Keeper_instructions | Active_goals | Direct_input_source | Completion_authority | Goals_awaiting_proof
  | Constitution_amendments | Operator_note | Arrived_stimuli -> true
;;

(* See the mli. [Keeper_instructions] never enters the extra-context assembly
   a resume carries; it answers [false] because a resumed session already holds
   the system prompt it recorded at its first launch. *)
let resent_when_held = function
  | Keeper_instructions | Dynamic_context | Active_goals | Direct_input_source | Constitution_amendments
  | Temporal_summary | Memory_os_recall | Librarian_working_context | Recalled_memory
  | Skill_compositions | Arrived_stimuli -> false
  | Completion_authority | Goals_awaiting_proof | Recalled_memory_status | Operator_note -> true
;;
