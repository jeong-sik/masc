(** Failure-path post-processing for [Keeper_unified_turn]. *)

module EC = Keeper_error_classify

(* RFC turn-failure-visible-stop (#32105): every turn failure advances the
   durable crash-accounting streak. There is no exemption class and no
   per-class budget. The historical exemption design kept a persistent
   transport outage retrying forever with [consecutive] pinned at 0 while
   fleet health stayed [ok] (#31958), and its "every exemption carries its
   own compensating accounting" invariant was enforced only by a comment
   that drifted from the code. Failure classification still exists for
   telemetry and routing; it no longer decides crash accounting. *)
let record_failure_observation
      ~(config : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~err
      ~error_text
  =
  let base_path = config.base_path in
  let count =
    Keeper_turn_failure_streak.increment ~base_path ~keeper_name:meta.name
  in
  Health.record_failure
    ~agent_name:meta.name
    ~reason:(Keeper_types_profile.short_preview error_text);
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
