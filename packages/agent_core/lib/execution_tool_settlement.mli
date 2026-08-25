type t

type durable_invocation = private
  { authority : t
  ; run_id : Execution_event.Run_id.t
  ; invocation : Tool_contract.Invocation.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type error =
  | Authority_unavailable of Execution_lane_writer.read_error
  | Invocation_not_found
  | Invocation_identity_mismatch
  | Effect_outcome_unknown
  | Attempt_admission_failed of Execution_lane_writer.submit_error
  | Attempt_commit_failed of Execution_lane_writer.ticket_error
  | Receipt_admission_outcome_unknown of Execution_lane_writer.submit_error
  | Receipt_settlement_outcome_unknown of Execution_lane_writer.ticket_error

type execution =
  | Executed of Llm_provider.Types.content_block * Execution_journal.cursor * int
  | Replayed of Llm_provider.Types.content_block

type phased_effect = private
  { result : Llm_provider.Types.content_block
  ; after_settle : unit -> unit
  }

val phased_effect
  :  result:Llm_provider.Types.content_block
  -> after_settle:(unit -> unit)
  -> phased_effect

(** Reconstruct one executable command from the journal's exact topology. *)
val rebind
  :  writer:Execution_lane_writer.t
  -> invocation_node:Execution_event.Node_id.t
  -> (durable_invocation, error) result

val execute
  :  t
  -> invoke:(unit -> Llm_provider.Types.content_block)
  -> (execution, error) result

val execute_with_attempt
  :  t
  -> invoke:(Execution_event.Node_id.t -> Llm_provider.Types.content_block)
  -> (execution, error) result

val execute_with_attempt_phased
  :  t
  -> invoke:(Execution_event.Node_id.t -> phased_effect)
  -> (execution, error) result

module For_testing : sig
  val execute_with_attempt_after_attempt_committed
    :  t
    -> after_attempt_committed:(unit -> unit)
    -> invoke:(Execution_event.Node_id.t -> Llm_provider.Types.content_block)
    -> (execution, error) result
end
