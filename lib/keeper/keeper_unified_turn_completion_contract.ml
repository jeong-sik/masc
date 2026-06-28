(** Completion-contract latch recovery for the unified keeper turn.

    Parallel of {!Keeper_unified_turn_no_progress} but for the
    completion-contract violation branch.

    Problem (RFC-0047 §3.2 / plan hypothesis B): an operator-triggered
    resume on a keeper latched by a completion-contract violation
    previously cleared [paused], [last_blocker], [failure_reason],
    [turn_consecutive_failures] — but did *not* clear the
    completion-contract detector state. On the very next cycle the
    detector fired again, the 3-strike gate re-engaged, and the keeper
    re-paused within seconds. Operators reported "resume doesn't stick".

    Fix: surface a typed recovery helper parallel to
    [Keeper_unified_turn_no_progress.clear_for_operator_resume] so the
    resume path can clear both latches in one shot.

    This module is purely additive: it does NOT introduce new pause or
    escalation behavior. New automatic pause/escalation logic is
    deliberately out of scope for this PR. *)

let failure_reason_code = "completion_contract_violation"

(** Clear the completion-contract latch for an operator-driven resume.

    Resets:
    - The [Keeper_registry.last_failure_reason] when its code matches
      ["completion_contract_violation"].
    - The [Keeper_meta_contract.runtime.last_blocker] when its klass
      is [Completion_contract_violation].

    Returns the (possibly mutated) meta. Does not touch paused state,
    turn_consecutive_failures, or any other field — those are the
    resume_reconcile_gate's responsibility.

    @param base_path  Keeper registry on-disk root.
    @param meta       Current keeper meta snapshot. *)
let clear_for_operator_resume ~base_path meta =
  let keeper_name = meta.Keeper_meta_contract.name in
  let cleared_failure_reason =
    match Keeper_registry.get ~base_path keeper_name with
    | Some { Keeper_registry.last_failure_reason =
               Some (Keeper_registry.Provider_runtime_error { code; _ })
           ; _
           } ->
      if String.equal code failure_reason_code then begin
        Keeper_registry.set_failure_reason ~base_path keeper_name None;
        true
      end
      else false
    | _ -> false
  in
  let cleared_meta_blocker =
    match meta.runtime.last_blocker with
    | Some { Keeper_meta_contract.klass =
                Keeper_meta_contract.Completion_contract_violation
            ; _
            } ->
      true
    | _ -> false
  in
  if cleared_failure_reason || cleared_meta_blocker then
    Log.Keeper.info
      "%s: operator resume cleared completion_contract_violation latch \
       (failure_reason=%b meta_blocker=%b)"
      keeper_name
      cleared_failure_reason
      cleared_meta_blocker;
  if cleared_meta_blocker then
    Keeper_meta_contract.map_runtime (fun rt -> { rt with last_blocker = None }) meta
  else
    meta
;;