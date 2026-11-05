val json_string : string -> Yojson.Safe.t -> string option
val composite_execution_receipt_json :
  config:Workspace.config ->
  keeper_name:string -> [> `Assoc of (string * Yojson.Safe.t) list ]
val composite_execution_config_blocked : Yojson.Safe.t -> bool
val keeper_activation_readiness_json :
  Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
val composite_execution_blocked : Yojson.Safe.t -> bool

(** The closed set of [runtime_attention.state] wire values. The registry
    judgment ({!composite_runtime_attention}) yields the first five; the
    offline fallback for a keeper without a registry entry yields
    [Attention_paused] or [Attention_offline]. *)
type runtime_attention_state =
  | Attention_blocked
  | Attention_stop_requested
  | Attention_idle_stale
  | Attention_stale
  | Attention_ok
  | Attention_paused
  | Attention_offline

val runtime_attention_state_to_wire : runtime_attention_state -> string
type composite_runtime_attention = {
  cra_is_live : bool;
  cra_fiber_stop_requested : bool;
  cra_idle_attention : bool;
  cra_blocked : bool;
  cra_execution_current : bool;
  cra_stale_execution_receipt : bool;
  cra_live_turn_started_at : float option;
  cra_live_turn_last_progress_at : float option;
  cra_needs_attention : bool;
  cra_reason : string option;
  cra_state : runtime_attention_state;
}
val composite_runtime_attention :
  snapshot:Yojson.Safe.t ->
  execution:Yojson.Safe.t -> composite_runtime_attention
val composite_runtime_attention_json :
  composite_runtime_attention ->
  snapshot:Yojson.Safe.t -> [> `Assoc of (string * Yojson.Safe.t) list ]
