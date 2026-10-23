(** Hook accumulator for Agent_core.Agent.run callbacks. The hooks write it
    during the run; the turn reads its fields after the run returns. *)

type hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : Keeper_agent_result.tool_call_detail list
    (** This invocation's executed calls only, newest first. *)
  ; mutable current_turn : int
  ; mutable tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; mutable receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  ; mutable prompt_blocks : Turn_record.prompt_block list
  ; mutable extra_system_context_digest : string option
  ; mutable extra_system_context_size : int option
  ; mutable extra_system_context_assembly : Keeper_context_assembly.t option
    (** The renderer-issued proof from the latest assembly. [None] means the
        assembly hook has not produced a value yet. Prefix coverage and empty
        carrier presence are preserved inside the immutable proof. *)
  ; mutable wire_prompt_tokens : Keeper_agent_result.wire_prompt_tokens option
    (** Sum of the turn's provider responses' wire [cache_n] / [prompt_n]. *)
  }

val create :
  meta:Keeper_meta_contract.keeper_meta ->
  tool_surface:Keeper_agent_tool_surface.tool_surface_metrics ->
  hook_accumulator
(** Begin a new invocation with no executed calls. *)

val record_requested_tool_names :
  hook_accumulator -> string list -> unit

(** Add the after_turn hook's response's wire [cache_n] / [prompt_n] to
    [wire_prompt_tokens]. A response that does not report both adds nothing. *)
val record_wire_prompt_tokens :
  hook_accumulator -> Agent_core.Types.api_response -> unit
