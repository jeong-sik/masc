(** Pure exact-attempt transition decisions. Every [Ok] requires the queue to
    persist, including [changed = false] idempotent rewrites. The planner does
    not authorize dispatch or publish any state: the durable write outcome does. *)
open Keeper_approval_queue_rules_types

open Keeper_approval_queue_result

type t = private
  { changed : bool
  ; updated_entry : pending_approval
  }

val bind
  :  candidate:exact_attempt_binding
  -> pending_approval
  -> (t, exact_attempt_error) result

val release
  :  candidate:exact_attempt_binding
  -> pending_approval
  -> (t, exact_attempt_error) result

val quarantine
  :  candidate:exact_attempt_binding
  -> cause:exact_attempt_quarantine_cause
  -> pending_approval
  -> (t, exact_attempt_error) result

val complete
  :  candidate:exact_attempt_binding
  -> summary:hitl_context_summary
  -> pending_approval
  -> (t, exact_attempt_error) result
