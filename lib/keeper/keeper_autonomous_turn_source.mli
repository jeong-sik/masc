(** Public dashboard read model for autonomous keeper turns.

    The current {!Turn_record.t} owns the closed turn kind, keeper/agent
    identity, generation, and exact OAS raw-trace run reference. This reader
    selects only [Autonomous] records and summarizes only that recorded run.
    It never scans or concatenates provider runs and never projects thinking,
    tool arguments, tool results, or other raw trace blocks onto the public
    chat endpoint. *)

type turn =
  { turn_id : string
  ; agent_name : string
  ; generation : int
  ; started_at : float
  ; finished_at : float option
  ; model : string option
  ; stop_reason : string option
  ; final_text : string option
  }

val default_limit : int
(** Newest current-schema turn records inspected per request. Raw trace file
    retention uses the same bound, so the endpoint does not imply reach beyond
    the files the writer keeps. *)

val load_recent :
  config:Workspace.config ->
  keeper_name:string ->
  ?limit:int ->
  ?since:float ->
  unit ->
  turn list
(** Returns exact-run autonomous turns oldest-first. Strictly incompatible
    turn records, missing/pruned raw traces, non-regular files, and failed run
    summaries are logged and skipped. There is no legacy decoder or fallback
    classifier. *)
