(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify

let record_failure_observation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~is_auto_recoverable
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let counts_toward_crash =
    (not is_auto_recoverable) || EC.is_runtime_exhausted_error err
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
