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
  -> usage_projection:Cost_ledger.usage_projection
  -> ?response_id:string
  -> ?runtime_attempt:(string * string * int)
  -> ?conversation:(string * Keeper_usage_resolution.cumulative_position)
  -> ?spend_observation:Keeper_spend_observation.t
  -> ?vendor_total_tokens:int
  -> ?resolution_status:Keeper_usage_resolution.status
  -> ?cache_creation_input_tokens:int
  -> ?cache_read_input_tokens:int
  -> ?usage_missing:bool
  -> ?usage_trust:Keeper_usage_trust.t
  -> ?telemetry:Agent_core.Types.inference_telemetry
  -> unit
  -> Yojson.Safe.t

(** Why a cost row is not in the ledger. *)
type append_failure =
  | Append_declined  (** The ledger's append guard did not run the append. *)
  | Append_raised of string
      (** The append raised before the row was in the file; the exception. *)

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
  -> usage_projection:Cost_ledger.usage_projection
  -> ?response_id:string
  -> ?runtime_attempt:(string * string * int)
  -> ?conversation:(string * Keeper_usage_resolution.cumulative_position)
  -> ?spend_observation:Keeper_spend_observation.t
  -> ?vendor_total_tokens:int
  -> ?resolution_status:Keeper_usage_resolution.status
  -> ?cache_creation_input_tokens:int
  -> ?cache_read_input_tokens:int
  -> ?usage_missing:bool
  -> ?usage_trust:Keeper_usage_trust.t
  -> ?telemetry:Agent_core.Types.inference_telemetry
  -> unit
  -> (unit, append_failure) result
(** Append one cost row. [Ok] means the row is in the ledger file. A failure
    is also logged and counted here, so a caller only decides what a row the
    ledger does not have means for it. *)
