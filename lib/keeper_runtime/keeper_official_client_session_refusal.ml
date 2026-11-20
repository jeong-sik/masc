type t =
  | Gate_continuation_unresumable
  | Gate_context_frontier_missing
  | Gate_canonical_context_changed
  | Claim_held_by_this_process
  | Task_reference_unsupported
  | Task_reference_unbound
  | Continuation_on_other_runtime

type Agent_core.Error.carrier += Official_client_session_refused of t

let all =
  [ Gate_continuation_unresumable
  ; Gate_context_frontier_missing
  ; Gate_canonical_context_changed
  ; Claim_held_by_this_process
  ; Task_reference_unsupported
  ; Task_reference_unbound
  ; Continuation_on_other_runtime
  ]
;;

let code = function
  | Gate_continuation_unresumable -> "official_client_gate_session_unresumable"
  | Gate_context_frontier_missing -> "official_client_gate_context_frontier_missing"
  | Gate_canonical_context_changed -> "official_client_gate_canonical_context_changed"
  | Claim_held_by_this_process -> "official_client_session_claim_held"
  | Task_reference_unsupported -> "official_client_task_reference_unsupported"
  | Task_reference_unbound -> "official_client_task_reference_unbound"
  | Continuation_on_other_runtime -> "official_client_continuation_on_other_runtime"
;;

let to_string = function
  | Gate_continuation_unresumable ->
    "original official-client Gate session is not resumable with this runtime and tool \
     surface"
  | Gate_context_frontier_missing ->
    "retained vendor conversation has no canonical context provenance; unchanged history \
     cannot be verified, so the Gate continuation cannot resume it"
  | Gate_canonical_context_changed ->
    "retained vendor conversation cannot replace its canonical history or core \
     instructions; the Gate continuation stops and the original session and effects \
     remain preserved"
  | Claim_held_by_this_process ->
    "official-client session claim is still owned by the current process epoch"
  | Task_reference_unsupported ->
    "this client cannot replace task-reference context without replaying it as user input"
  | Task_reference_unbound ->
    "historical task reference is not bound to this operation's original vendor session"
  | Continuation_on_other_runtime ->
    "official-client continuation is bound to another lane candidate's runtime; this \
     candidate cannot resume it"
;;

type lane_step =
  | Next_candidate
  | Stop_lane

let lane_step = function
  | Task_reference_unsupported | Continuation_on_other_runtime -> Next_candidate
  | Gate_continuation_unresumable
  | Gate_context_frontier_missing
  | Gate_canonical_context_changed
  | Claim_held_by_this_process
  | Task_reference_unbound -> Stop_lane
;;

let core_error refusal =
  Agent_core.Error.Internal_carried
    { message = to_string refusal; carrier = Official_client_session_refused refusal }
;;

let of_core_error = function
  | Agent_core.Error.Internal_carried { carrier = Official_client_session_refused refusal; _ }
    -> Some refusal
  | ( Agent_core.Error.Api _
    | Provider _
    | Agent _
    | Mcp _
    | Config _
    | Serialization _
    | Io _
    | Orchestration _ | Media _
    | Internal _
    | Internal_carried _ ) -> None
;;

let should_try_next error =
  match of_core_error error with
  | Some refusal ->
    (match lane_step refusal with
     | Next_candidate -> true
     | Stop_lane -> false)
  | None -> false
;;
