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
   so restarts cannot reset the bound either. *)
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

let record_failure_observation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~is_auto_recoverable
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let invalid_request_budget_exhausted =
    EC.is_invalid_request_error err
    && note_invalid_request_failure ~keeper_name:meta.name
  in
  if invalid_request_budget_exhausted
  then
    Log.Keeper.warn
      "%s: deterministic invalid-request failures exceeded %d consecutive \
       attempts; degrading to ordinary crash accounting: %s"
      meta.name
      max_consecutive_invalid_request_failures
      (Keeper_types_profile.short_preview error_text);
  let counts_toward_crash =
    (not is_auto_recoverable)
    || EC.is_runtime_exhausted_error err
    || invalid_request_budget_exhausted
  in
  if counts_toward_crash
  then (
    Keeper_registry.increment_turn_failures ~base_path meta.name;
    Health.record_failure
      ~agent_name:meta.name
      ~reason:(Keeper_types_profile.short_preview error_text))
  else
    Log.Keeper.info
      "%s: auto-recoverable turn failure (not counted toward crash threshold): %s"
      meta.name
      (Keeper_types_profile.short_preview error_text);
  let count = Keeper_registry.get_turn_failures ~base_path meta.name in
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
