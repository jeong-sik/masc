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
  (* Runtime-dependent failures: a DIFFERENT runtime (other credentials or
     model) may succeed, so rotate — never escalate. This matches the
     current production behavior: [recoverable_runtime_failure_reason]
     returns a [Some] reason for exactly these (they are the rotation-
     recoverable set), and the credential-pool candidate filter already
     rotates auth/no-progress. Auth = this runtime's credential is invalid
     (a different runtime's is not); no-progress = this model made no
     progress on this input (a different model may). Correction: these were
     mis-routed to [Escalate_judgment] in the first W2a landing — a
     [degraded_retry_reason] is by construction rotation-recoverable, so
     none of them is a judgment stimulus. *)
  | Keeper_error_classify.Runtime_candidates_filtered
  | Keeper_error_classify.Auth_error
  | Keeper_error_classify.Read_only_no_progress
  | Keeper_error_classify.Empty_no_progress
  | Keeper_error_classify.Thinking_only_no_progress -> Rotate_now
(* [Escalate_judgment] is intentionally unreachable from this projection:
   every [degraded_retry_reason] is rotation-recoverable. Deterministic
   errors that warrant a judgment stimulus (config / schema / contract /
   Mcp / catalog illegal-state) are the ones [recoverable_runtime_failure_
   reason] maps to [None] — i.e. they never become a [degraded_retry_reason]
   at all, and are routed by the sdk-error-level total router, not here. The
   [Escalate_judgment] constructor stays in the [route] type for that
   caller. *)

let is_deterministic = function
  | Escalate_judgment -> true
  | Retry_after_pacing | Rotate_now -> false
