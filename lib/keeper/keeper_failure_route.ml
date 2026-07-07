(* RFC-0313 W2a — total routing of a degraded failure reason.
   See keeper_failure_route.mli. *)

type route =
  | Retry_after_pacing
  | Rotate_now
  | Escalate_judgment

let route_to_string = function
  | Retry_after_pacing -> "retry_after_pacing"
  | Rotate_now -> "rotate_now"
  | Escalate_judgment -> "escalate_judgment"

(* Exhaustive over every [degraded_retry_reason] constructor — NO
   catch-all. A new reason added to that closed set forces a compile
   error here, so the projection can never silently misroute a novel
   failure (CLAUDE.md "FSM Sparse Match" / no [_ ->]). Each arm cites
   the RFC-0313 §2 route table row it implements. *)
let of_degraded_retry_reason (reason : Keeper_error_classify.degraded_retry_reason)
  : route
  =
  match reason with
  (* Transient / capacity / timeout: pace the revisit, honor retry_after. *)
  | Keeper_error_classify.Hard_quota
  | Keeper_error_classify.Rate_limit
  | Keeper_error_classify.Capacity_backpressure
  | Keeper_error_classify.Server_error
  | Keeper_error_classify.Provider_timeout
  | Keeper_error_classify.Turn_timeout
  | Keeper_error_classify.Admission_queue_timeout
  | Keeper_error_classify.Runtime_exhausted
  | Keeper_error_classify.Resumable_cli_session -> Retry_after_pacing
  (* Provider-bound with candidates left to try: rotate on this turn. *)
  | Keeper_error_classify.Runtime_candidates_filtered -> Rotate_now
  (* Deterministic: retrying cannot help. Auth is a config/credential
     fact; the three no-progress accept-rejections are model-behavior
     facts. Both become stimuli for an LLM-boundary verdict, not retries. *)
  | Keeper_error_classify.Auth_error
  | Keeper_error_classify.Read_only_no_progress
  | Keeper_error_classify.Empty_no_progress
  | Keeper_error_classify.Thinking_only_no_progress -> Escalate_judgment

let is_deterministic = function
  | Escalate_judgment -> true
  | Retry_after_pacing | Rotate_now -> false
