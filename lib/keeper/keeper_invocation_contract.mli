(** Typed MASC boundary for invoking one Keeper.

    This module owns no registry and starts no parallel scheduler. It projects
    the existing durable {!Keeper_msg_async} owner into typed direct-message
    input, target, capability, run reference, and result contract. *)

type capability = Invoke_turn

type target = Keeper of Keeper_id.Keeper_name.t

type request

type direct_message
(** Current direct-turn input after an adapter has decoded its wire request.
    It contains exactly the turn-owned fields: target and prompt,
    [direct_reply], optional turn/surface context, optional channel session,
    channel label, semantic user blocks, and attachments. Connector identity
    and metadata stay at their adapter boundary. *)

type run_ref

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
  | Invalid_multimodal_input of string
  | Invalid_wire_value of
      { field : string
      ; expected : string
      }
  | Run_ref_mismatch

val request : keeper_name:string -> prompt:string -> (request, request_error) result

val direct_message :
  keeper_name:string ->
  prompt:string ->
  direct_reply:bool ->
  ?turn_instructions:string ->
  ?surface_context:Yojson.Safe.t ->
  ?channel_session_key:string ->
  channel:string ->
  user_blocks:Keeper_multimodal_input.user_input_block list ->
  attachments:Keeper_chat_store.attachment list ->
  unit ->
  (direct_message, request_error) result

val direct_message_with_keeper_name :
  direct_message -> string -> (direct_message, request_error) result

val direct_message_request : direct_message -> request
val direct_message_target_name : direct_message -> string
val direct_message_prompt : direct_message -> string
val direct_message_direct_reply : direct_message -> bool
val direct_message_turn_instructions : direct_message -> string option
val direct_message_surface_context : direct_message -> Yojson.Safe.t option
val direct_message_channel_session_key : direct_message -> string option
val direct_message_channel : direct_message -> string

val direct_message_user_blocks :
  direct_message -> Keeper_multimodal_input.user_input_block list

val direct_message_attachments :
  direct_message -> Keeper_chat_store.attachment list

val direct_message_user_oas_blocks :
  direct_message -> Agent_sdk.Types.content_block list option

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

val submission_to_json
  :  request -> Keeper_msg_async.submit_outcome -> Yojson.Safe.t

val delegate_submission_to_json
  :  request -> Keeper_msg_async.submit_outcome -> Yojson.Safe.t

val delegate_submission_error_to_json
  :  request -> Keeper_msg_async.submit_error -> Yojson.Safe.t

val delegate_cancellation_to_json
  :  run_ref -> Keeper_msg_async.cancel_result -> Yojson.Safe.t

val entry_to_json
  :  Keeper_msg_async.entry
  -> (Yojson.Safe.t, request_error) result

val delegate_entry_to_json
  :  Keeper_msg_async.entry
  -> (Yojson.Safe.t, request_error) result
