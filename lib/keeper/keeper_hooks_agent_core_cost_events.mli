(** Cost ledger event helpers for [Keeper_hooks_agent_core]. *)

type assembled_cost_event_payload =
  { payload : Yojson.Safe.t
  ; provider : string
  ; cost_status_label : string
  ; cost_status_reason_label : string
  ; cost_usd_source : string
  }

val cost_emit_source_metric : string

val classify_cost_usd_source
  :  usage_missing:bool
  -> runtime_unmetered:bool
  -> cost_usd:float
  -> string

val record_cost_emit_source : string -> unit

val cache_miss_input_tokens
  :  input_tokens:int
  -> cache_creation_input_tokens:int
  -> cache_read_input_tokens:int
  -> int

val cost_event_payload
  :  agent_name:string
  -> task_id:string option
  -> trace_id:string
  -> keeper_turn_id:int
  -> agent_core_turn_ordinal:int
  -> model:string
  -> input_tokens:int
  -> output_tokens:int
  -> cost_usd:float
  -> ?usage_projection:Cost_ledger.usage_projection
  -> ?cache_creation_input_tokens:int
  -> ?cache_read_input_tokens:int
  -> ?usage_missing:bool
  -> ?usage_trust:Keeper_usage_trust.t
  -> ?telemetry:Agent_core.Types.inference_telemetry
  -> unit
  -> Yojson.Safe.t

val emit_cost_event
  :  masc_root:string
  -> agent_name:string
  -> task_id:string option
  -> trace_id:string
  -> keeper_turn_id:int
  -> agent_core_turn_ordinal:int
  -> model:string
  -> input_tokens:int
  -> output_tokens:int
  -> cost_usd:float
  -> ?usage_projection:Cost_ledger.usage_projection
  -> ?cache_creation_input_tokens:int
  -> ?cache_read_input_tokens:int
  -> ?usage_missing:bool
  -> ?usage_trust:Keeper_usage_trust.t
  -> ?telemetry:Agent_core.Types.inference_telemetry
  -> unit
  -> unit
