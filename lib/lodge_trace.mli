(** Lodge Trace — Prompt/Response capture and file I/O for tuning.

    Captures full prompt, response, timing, and action for each LLM call
    during heartbeat ticks. Traces are written to per-agent JSONL files
    under [~/.masc/traces/<agent_name>/<date>.jsonl].

    @since 4.1.0 — Extracted from lodge_heartbeat.ml
*)

(** Trace entry: captures full prompt, response, timing, and action *)
type trace_entry = {
  tick_id : string;
  agent_name : string;
  phase : string;
  prompt : string;
  response : string;
  llm_used : string;
  action : string;
  duration_ms : int;
  timestamp : float;
}

(** Save a trace entry to the agent's JSONL trace file.
    Creates directories if they do not exist. *)
val save : trace_entry -> unit
