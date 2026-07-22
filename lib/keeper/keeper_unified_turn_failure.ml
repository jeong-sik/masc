(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify

(** Bounded compensating accounting for the empty-completion exemption in
    [EC.is_auto_recoverable_turn_error].  The exemption skips
    [increment_turn_failures], so without a bound a model that
    deterministically returns empty turns retries forever with the crash
    counter pinned at 0 — the same failure mode as the 2026-07-21 provider
    parse-rejection loop.  Each keeper gets
    [empty_completion_exemption_budget] consecutive exempted empty-completion
    failures; the next one counts toward the crash threshold again.  A
    successful turn (or an operator context clear) resets the budget via
    {!note_turn_success}. *)
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

(** Compute whether this failure observation advances the crash counter,
    consuming empty-completion exemption budget when applicable.  Call exactly
    once per failure observation, before {!record_failure_observation}. *)
let account_failure_counting ~keeper_name ~is_auto_recoverable err =
  (not is_auto_recoverable)
  || EC.is_runtime_exhausted_error err
  || empty_completion_exemption_exhausted ~keeper_name err
;;

let record_failure_observation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~counts_toward_crash
      ~err
      ~error_text
  =
  let base_path = config.base_path in
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
