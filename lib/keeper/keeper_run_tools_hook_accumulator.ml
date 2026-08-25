(** Hook accumulator + outputs for Agent_core.Agent.run hook callbacks,
    extracted from keeper_run_tools.ml.

    AGENT_CORE hooks (before_turn, on_tool_executed) cannot return values, so
    they write into a single mutable {!hook_accumulator} during
    Agent.run execution.  After execution completes, {!freeze} produces
    an immutable {!hook_outputs} snapshot. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result

type hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
    (* RFC-0233 PR-3: last agent-core turn's context assembly, written by the
       before_turn_params hook, read at the receipt/TurnRecord write site
       in run_turn. Last-write-wins matches the turn-context cell
       semantics the receipt already uses. *)
  ; mutable receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
    (* Root B (#22710): world-observation actionable signal computed from the
       turn's [world_observation] in run_turn, carried into the receipt so
       [operator_disposition] can replace the [goal_ids = []] proxy. [None]
       until the contract-status write site sets it. *)
  ; mutable prompt_blocks : Turn_record.prompt_block list
  ; mutable extra_system_context_digest : string option
  ; mutable extra_system_context_size : int option
  ; mutable assistant_turn_texts : string list
    (* One entry per completed provider turn, newest first, written by the
       after_turn hook and read by the cooperative-yield probe's
       repeated-assistant-text detector. Each entry is the turn's [Text]
       blocks concatenated in emission order with no separator and no other
       transformation; thinking, reasoning, and tool blocks are excluded. A
       turn without a [Text] block contributes "" so positions stay aligned
       with provider turns — blank entries never satisfy the detector, they
       only break a streak. *)
  }

type hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; out_receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  }

let freeze (acc : hook_accumulator) : hook_outputs =
  { out_meta = acc.meta
  ; out_tool_calls = acc.tool_calls
  ; out_tool_surface = acc.tool_surface
  ; out_requested_tool_names = acc.requested_tool_names
  ; out_receipt_completion_contract_result = acc.receipt_completion_contract_result
  ; out_receipt_actionable_signal = acc.receipt_actionable_signal
  }
;;

let record_requested_tool_names (acc : hook_accumulator) requested =
  acc.requested_tool_names <- requested
;;

let record_assistant_turn_text
      (acc : hook_accumulator)
      (response : Agent_core.Types.api_response)
  =
  let turn_text =
    response.Agent_core.Types.content
    |> List.filter_map (function
      | Agent_core.Types.Text text -> Some text
      | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _
      | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ToolUse _
      | Agent_core.Types.ToolResult _
      | Agent_core.Types.Image _
      | Agent_core.Types.Document _
      | Agent_core.Types.Audio _ -> None)
    |> String.concat ""
  in
  acc.assistant_turn_texts <- turn_text :: acc.assistant_turn_texts
;;
