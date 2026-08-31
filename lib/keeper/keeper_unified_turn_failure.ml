(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify

(* Compensating accounting for deterministic [InvalidRequest] failures (see
   the invariant note in [Keeper_error_classify] above
   [is_auto_recoverable_turn_error]). That class is exempt from the crash
   counter, so without its own bound a poisoned checkpoint would re-emit the
   same 400 every cycle with [consecutive] pinned at 0 — the same shape as
   the 2026-07-21 provider-parse-rejection incident. The counter is
   process-local, which is where the unbounded loop lives; once the bound is
   exceeded the observation degrades to ordinary (durable) crash accounting,
   so restarts cannot reset the bound either.

   Constitution exception (named bound + rationale): this number gates only
   crash ACCOUNTING, never the keeper lifecycle — the keeper stays active
   either way (see the "Keeper lifecycle remains active" log in
   [record_failure_observation]). The failure class is deterministic
   (identical request, identical 400), so the bound is not there to absorb
   flakiness; 3 gives a poisoned checkpoint a few cycles in which an
   intervening operator context clear can change the request
   before durable accounting resumes. *)
let max_consecutive_invalid_request_failures = 3

let invalid_request_consecutive : (string, int) Hashtbl.t = Hashtbl.create 8

let note_invalid_request_failure ~keeper_name =
  let n =
    (match Hashtbl.find_opt invalid_request_consecutive keeper_name with
     | Some n -> n
     | None -> 0)
    + 1
  in
  Hashtbl.replace invalid_request_consecutive keeper_name n;
  n > max_consecutive_invalid_request_failures
;;

let reset_invalid_request_failures ~keeper_name =
  Hashtbl.remove invalid_request_consecutive keeper_name
;;

(** Bounded compensating accounting for the empty-completion exemption in
    [EC.is_auto_recoverable_turn_error].  The exemption skips
    [increment_turn_failures], so without a bound a model that
    deterministically returns empty turns retries forever with the crash
    counter pinned at 0 — the same failure mode as the 2026-07-21 provider
    parse-rejection loop.  Each keeper gets
    [empty_completion_exemption_budget] consecutive exempted empty-completion
    failures; the next one counts toward the crash threshold again.  A
    successful turn (or an operator context clear) resets the budget via
    {!note_turn_success}.

    Constitution exception (named bound + rationale): like the
    [InvalidRequest] bound above, this gates crash ACCOUNTING only, not the
    keeper lifecycle.  Unlike [InvalidRequest], an empty completion can be
    transient provider flakiness (a degraded backend answering empty turns
    while it recovers), so the budget deliberately leaves room — 5
    consecutive exempted failures — for the provider to recover across
    cycles before the failure class degrades to durable crash accounting. *)
let empty_completion_exemption_budget = 5

let empty_completion_exemptions : (string, int) Hashtbl.t = Hashtbl.create 8

let note_turn_success keeper_name =
  Hashtbl.remove empty_completion_exemptions keeper_name
;;

let empty_completion_exemption_exhausted ~keeper_name err =
  if not (EC.is_empty_completion_error err)
  then false
  else (
    let used =
      Option.value
        ~default:0
        (Hashtbl.find_opt empty_completion_exemptions keeper_name)
      + 1
    in
    Hashtbl.replace empty_completion_exemptions keeper_name used;
    used > empty_completion_exemption_budget)
;;

(* Consume one [InvalidRequest] budget unit for [keeper_name] when [err] is
   in that class; returns [true] once the consecutive bound is exceeded.
   Separate counter from the empty-completion budget above — the two
   exemption classes never share units. *)
let invalid_request_budget_exhausted ~keeper_name err =
  if not (EC.is_invalid_request_error err)
  then false
  else (
    let exhausted = note_invalid_request_failure ~keeper_name in
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
let account_failure_counting ~keeper_name ~is_auto_recoverable err =
  (not is_auto_recoverable)
  || EC.is_runtime_exhausted_error err
  || empty_completion_exemption_exhausted ~keeper_name err
  || invalid_request_budget_exhausted ~keeper_name err
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
