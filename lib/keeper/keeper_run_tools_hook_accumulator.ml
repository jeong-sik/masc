(** Hook accumulator for Agent_core.Agent.run hook callbacks, extracted
    from keeper_run_tools.ml.

    AGENT_CORE hooks (before_turn, on_tool_executed) cannot return values, so
    they write into a single mutable {!hook_accumulator} during
    Agent.run execution. After the run returns, the turn reads its fields
    directly. *)

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
  ; mutable extra_system_context_assembly : Keeper_context_assembly.t option
    (** The renderer-issued proof from the latest assembly. [None] means the
        assembly hook has not produced a value yet. Prefix coverage and empty
        carrier presence are preserved inside the immutable proof. *)
  ; mutable wire_prompt_tokens : Keeper_agent_result.wire_prompt_tokens option
    (* Sum of the turn's provider responses' wire [cache_n] / [prompt_n],
       written by the after_turn hook. *)
  }

let create ~meta ~tool_surface =
  { meta
  ; tool_calls = []
  ; current_turn = 0
  ; tool_surface
  ; requested_tool_names = []
  ; receipt_completion_contract_result =
      Keeper_execution_receipt.Completion_observation_unknown
  ; receipt_actionable_signal = None
  ; prompt_blocks = []
  ; extra_system_context_digest = None
  ; extra_system_context_size = None
  ; extra_system_context_assembly = None
  ; wire_prompt_tokens = None
  }
;;

let record_requested_tool_names (acc : hook_accumulator) requested =
  acc.requested_tool_names <- requested
;;

let record_wire_prompt_tokens
      (acc : hook_accumulator)
      (response : Agent_core.Types.api_response)
  =
  match response.Agent_core.Types.telemetry with
  | Some
      { Agent_core.Types.timings =
          Some { Agent_core.Types.cache_n = Some cache_n; prompt_n = Some prompt_n; _ }
      ; _
      } ->
    acc.wire_prompt_tokens
    <- Some
         (match acc.wire_prompt_tokens with
          | None -> { Keeper_agent_result.cache_n; prompt_n }
          | Some sum ->
            { Keeper_agent_result.cache_n = sum.cache_n + cache_n
            ; prompt_n = sum.prompt_n + prompt_n
            })
  | Some { timings = Some _; _ } | Some { timings = None; _ } | None -> ()
;;
