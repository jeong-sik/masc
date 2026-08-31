(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify
module Exemption_store = Keeper_failure_exemption_store

(* Compensating accounting for deterministic [InvalidRequest] failures (see
   the invariant note in [Keeper_error_classify] above
   [is_auto_recoverable_turn_error]). That class is exempt from the crash
   counter, so without its own bound a poisoned checkpoint would re-emit the
   same 400 every cycle with [consecutive] pinned at 0 — the same shape as
   the 2026-07-21 provider-parse-rejection incident. The counter is
   durable across process restart. Once the bound is exceeded the observation
   degrades to ordinary durable crash accounting.

   Constitution exception (named bound + rationale): this number gates only
   crash ACCOUNTING, never the keeper lifecycle — the keeper stays active
   either way (see the "Keeper lifecycle remains active" log in
   [record_failure_observation]). The failure class is deterministic
   (identical request, identical 400), so the bound is not there to absorb
   flakiness; 3 gives a poisoned checkpoint a few cycles in which an
   intervening operator context clear can change the request
   before durable accounting resumes. *)
let max_consecutive_invalid_request_failures = 3

let persist_exemption_increment ~base_path ~keeper_name update =
  match Exemption_store.load ~base_path ~keeper_name with
  | Error error -> Error error
  | Ok persisted ->
    let state = update (Option.value ~default:Exemption_store.zero persisted) in
    Result.map (fun () -> state) (Exemption_store.save ~base_path ~keeper_name state)
;;

let note_invalid_request_failure ~base_path ~keeper_name =
  match
    persist_exemption_increment ~base_path ~keeper_name (fun state ->
      { state with invalid_request_count = state.invalid_request_count + 1 })
  with
  | Ok state -> state.invalid_request_count > max_consecutive_invalid_request_failures
  | Error error ->
    Log.Keeper.error
      ~keeper_name
      "%s: invalid-request exemption unavailable; counting failure toward crash: %s"
      keeper_name
      (Exemption_store.error_to_string error);
    true
;;

(** Bounded compensating accounting for the empty-completion exemption in
    [EC.is_auto_recoverable_turn_error].  The exemption skips
    [increment_turn_failures], so without a bound a model that
    deterministically returns empty turns retries forever with the crash
    counter pinned at 0 — the same failure mode as the 2026-07-21 provider
    parse-rejection loop.  Each keeper gets
    [empty_completion_exemption_budget] consecutive exempted empty-completion
    failures; the next one counts toward the crash threshold again.  A
    successful turn (or an operator context clear) resets the durable budget
    via {!reset_failure_exemptions}.

    Constitution exception (named bound + rationale): like the
    [InvalidRequest] bound above, this gates crash ACCOUNTING only, not the
    keeper lifecycle.  Unlike [InvalidRequest], an empty completion can be
    transient provider flakiness (a degraded backend answering empty turns
    while it recovers), so the budget deliberately leaves room — 5
    consecutive exempted failures — for the provider to recover across
    cycles before the failure class degrades to durable crash accounting. *)
let empty_completion_exemption_budget = 5

let reset_failure_exemptions ~base_path ~keeper_name =
  match Exemption_store.clear ~base_path ~keeper_name with
  | Ok () -> true
  | Error error ->
    Log.Keeper.error
      ~keeper_name
      "%s: retaining failure exemption state because durable reset did not commit: %s"
      keeper_name
      (Exemption_store.error_to_string error);
    false
;;

let empty_completion_exemption_exhausted ~base_path ~keeper_name err =
  if not (EC.is_empty_completion_error err)
  then false
  else
    match
      persist_exemption_increment ~base_path ~keeper_name (fun state ->
        { state with empty_completion_count = state.empty_completion_count + 1 })
    with
    | Ok state -> state.empty_completion_count > empty_completion_exemption_budget
    | Error error ->
      Log.Keeper.error
        ~keeper_name
        "%s: empty-completion exemption unavailable; counting failure toward crash: %s"
        keeper_name
        (Exemption_store.error_to_string error);
      true
;;

(* Consume one [InvalidRequest] budget unit for [keeper_name] when [err] is
   in that class; returns [true] once the consecutive bound is exceeded.
   Separate counter from the empty-completion budget above — the two
   exemption classes never share units. *)
let invalid_request_budget_exhausted ~base_path ~keeper_name err =
  if not (EC.is_invalid_request_error err)
  then false
  else (
    let exhausted = note_invalid_request_failure ~base_path ~keeper_name in
    if exhausted
    then
      Log.Keeper.warn
        "%s: deterministic invalid-request failures exceeded %d consecutive \
         attempts; degrading to ordinary crash accounting: %s"
        keeper_name
        max_consecutive_invalid_request_failures
        (Keeper_types_profile.short_preview (Agent_core.Error.to_string err));
    exhausted)
;;

(** Compute whether this failure observation advances the crash counter,
    consuming empty-completion exemption budget or invalid-request budget
    when applicable.  Call exactly once per failure observation, before
    {!record_failure_observation}. *)
let account_failure_counting ~base_path ~keeper_name ~is_auto_recoverable err =
  (not is_auto_recoverable)
  || EC.is_runtime_exhausted_error err
  || empty_completion_exemption_exhausted ~base_path ~keeper_name err
  || invalid_request_budget_exhausted ~base_path ~keeper_name err
;;

let record_failure_observation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~counts_toward_crash
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let count =
    if counts_toward_crash
    then (
      let count =
        Keeper_turn_failure_streak.increment
          ~base_path
          ~keeper_name:meta.name
      in
    Health.record_failure
      ~agent_name:meta.name
        ~reason:(Keeper_types_profile.short_preview error_text);
      count)
    else (
    Log.Keeper.info
      "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
      meta.name
        (Keeper_types_profile.short_preview error_text);
      Keeper_registry.get_turn_failures ~base_path meta.name)
  in
  if EC.is_runtime_exhausted_error err && count > 0
  then
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some (Keeper_registry.Turn_consecutive_failures count));
  Log.Keeper.warn
    "%s: turn failure observed (consecutive=%d); Keeper lifecycle remains active: %s"
    meta.name
    count
    (Keeper_types_profile.short_preview error_text)
;;
