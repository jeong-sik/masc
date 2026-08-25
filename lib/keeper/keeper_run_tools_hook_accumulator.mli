(** Hook accumulator + immutable outputs for Agent_core.Agent.run callbacks. *)

type hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : Keeper_agent_result.tool_call_detail list
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
  ; mutable assistant_turn_texts : string list
    (** One entry per completed provider turn, newest first: the turn's [Text]
        blocks concatenated in emission order, "" when the turn emitted none.
        Thinking, reasoning, and tool blocks are excluded. *)
  }

type hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : Keeper_agent_result.tool_call_detail list
  ; out_tool_surface : Keeper_agent_tool_surface.tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; out_receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  }

val freeze : hook_accumulator -> hook_outputs

val record_requested_tool_names :
  hook_accumulator -> string list -> unit

(** Append the provider turn's assistant text (see [assistant_turn_texts])
    from the after_turn hook's response. *)
val record_assistant_turn_text :
  hook_accumulator -> Agent_core.Types.api_response -> unit
