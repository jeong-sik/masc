(** Dashboard read model for autonomous keeper turns.

    The current {!Turn_record.t} owns the closed turn kind, keeper/agent
    identity, generation, and exact AGENT_CORE raw-trace run reference. This reader
    selects only [Autonomous] records and projects only that recorded run.
    Final text and typed execution steps come from the same exact raw trace;
    it never scans or concatenates provider runs. *)

type turn =
  { turn_id : string
  ; started_at : float
  ; final_text : string option
  ; trace : Keeper_chat_blocks.trace_step list
  }

val load_recent :
  config:Workspace.config ->
  keeper_name:string ->
  ?limit:int ->
  ?since:float ->
  unit ->
  turn list
(** Returns exact-run autonomous turns oldest-first. [Autonomous] records with
    no exact run are a typed absence and are skipped without a warning.
    Strictly incompatible records, unexpectedly missing/non-regular referenced
    traces, and failed run summaries are logged and skipped. There is no legacy
    decoder or fallback classifier. *)
