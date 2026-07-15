(** Typed MASC boundary for invoking one Keeper from another tool lane.

    This module owns no registry and starts no parallel scheduler. It projects
    the existing durable {!Keeper_msg_async} owner into a typed target,
    capability, run reference, and result contract. *)

type capability = Invoke_turn

type target = Keeper of Keeper_id.Keeper_name.t

type request

type run_ref =
  { run_id : string
  ; target : target
  ; capability : capability
  }

type submission_receipt =
  | Durable_run of run_ref
  | Reconciliation_required of
      { run_ref : run_ref
      ; reason : string
      }

type result_contract =
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
  | Invalid_entry_projection

val request : keeper_name:string -> prompt:string -> (request, request_error) result
val request_error_to_string : request_error -> string
val target_name : request -> string
val prompt : request -> string

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

val submission_to_json
  :  request -> Keeper_msg_async.submit_outcome -> Yojson.Safe.t

val entry_to_json
  :  Keeper_msg_async.entry
  -> (Yojson.Safe.t, request_error) result
