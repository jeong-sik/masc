(** Typed MASC boundary for invoking one Keeper from another tool lane.

    This module owns no registry and starts no parallel scheduler. It projects
    the existing durable {!Keeper_msg_async} owner into a typed target,
    capability, run reference, and result contract. *)

type capability = Keeper_invocation_types.capability = Invoke_turn

type target = Keeper_invocation_types.target = Keeper of Keeper_id.Keeper_name.t

type request

type run_ref = Keeper_invocation_types.run_ref

type submission_receipt =
  | Durable_run of run_ref
  | Reconciliation_required of
      { run_ref : run_ref
      ; reason : string
      }

type result_contract = Keeper_invocation_types.result_contract =
  | Awaiting_execution
  | Publication_uncertain
  | Running
  | Yielded
  | Cancellation_requested
  | Cancelled
  | Completed
  | Failed

type request_error =
  | Invalid_target of string
  | Empty_prompt
  | Invalid_wire_value of
      { field : string
      ; expected : string
      }
  | Run_ref_mismatch

val request : keeper_name:string -> prompt:string -> (request, request_error) result
val request_of_json : Yojson.Safe.t -> (request, request_error) result
val request_error_to_string : request_error -> string
val target_name : request -> string
val prompt : request -> string
val target_of_json : Yojson.Safe.t -> (target, request_error) result
val target_to_json : target -> Yojson.Safe.t
val target_name_of_target : target -> string
val run_ref_of_json : Yojson.Safe.t -> (run_ref, request_error) result
val run_ref_to_json : run_ref -> Yojson.Safe.t
val run_id : run_ref -> string
val run_ref_target_name : run_ref -> string
val run_ref_matches_entry : run_ref -> Keeper_msg_async.entry -> bool

val submit
  :  background_sw:Eio.Switch.t
  -> base_path:string
  -> caller:string
  -> request:request
  -> f:(request -> Eio.Switch.t -> Keeper_types_profile.tool_result)
  -> unit
  -> (Keeper_msg_async.submit_outcome, Keeper_msg_async.submit_error) result

val submission_receipt
  :  request -> Keeper_msg_async.submit_outcome -> submission_receipt

val result_contract : Keeper_msg_async.entry -> result_contract
val result_contract_to_string : result_contract -> string
val result_contract_of_string : string -> result_contract option

val delegate_submission_to_json
  :  request -> Keeper_msg_async.submit_outcome -> Yojson.Safe.t

val delegate_submission_error_to_json
  :  request -> Keeper_msg_async.submit_error -> Yojson.Safe.t

val delegate_cancellation_to_json
  :  run_ref -> Keeper_msg_async.cancel_result -> Yojson.Safe.t

val delegate_entry_to_json
  :  Keeper_msg_async.entry
  -> (Yojson.Safe.t, request_error) result
