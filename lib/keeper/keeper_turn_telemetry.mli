(** Keeper_turn_telemetry — post-turn observability logging.

    Extracted from keeper_agent_run.ml as part of #5732 god-module split.
    Retired contract-verification proof / verdict helpers are absent; only
    memory-bank write logging remains. *)

(** Log a memory-bank write summary. Promoted to info level when
    [notes_written >= 10], otherwise debug. *)
val log_keeper_memory_write :
  keeper_name:string ->
  notes_written:int ->
  kinds_written:string list ->
  unit
