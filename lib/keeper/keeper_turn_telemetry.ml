(** Keeper_turn_telemetry — post-turn observability logging.

    Extracted from keeper_agent_run.ml as part of #5732 god-module split.
    Contract-verification proof / contract-verdict / friction logging helpers were removed
    when verification collapsed to [Task_completion_gate]; only memory-bank
    write logging remains. *)

let log_keeper_memory_write
      ~(keeper_name : string)
      ~(notes_written : int)
      ~(kinds_written : string list)
  =
  if notes_written >= 10
  then
    Log.Keeper.info ~keeper_name:keeper_name
      "memory_write: %d notes, kinds=[%s]"
      notes_written
      (String.concat "," kinds_written)
  else if Keeper_types_profile.keeper_debug
  then
    Log.Keeper.debug ~keeper_name:keeper_name
      "memory_write: %d notes, kinds=[%s]"
      notes_written
      (String.concat "," kinds_written)
;;
