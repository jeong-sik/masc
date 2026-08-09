(** Typed input boundary for submitting one Keeper chat operation. *)

type capability = Invoke_turn

type target = Keeper of Keeper_id.Keeper_name.t

type request

type direct_message
(** Current direct-turn input after an adapter has decoded its wire request.
    It contains exactly the turn-owned fields: target and prompt,
    [direct_reply], optional turn/surface context, optional channel session,
    channel label, semantic user blocks, and attachments. Connector identity
    and metadata stay at their adapter boundary. *)

type request_error =
  | Invalid_target of string
  | Empty_prompt
  | Invalid_multimodal_input of string
  | Invalid_wire_value of
      { field : string
      ; expected : string
      }

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

val direct_message_user_agent_core_blocks :
  direct_message -> Agent_core.Types.content_block list option

val request_of_json : Yojson.Safe.t -> (request, request_error) result
val request_error_to_string : request_error -> string
val target_name : request -> string
val prompt : request -> string
val target_of_json : Yojson.Safe.t -> (target, request_error) result
val target_name_of_target : target -> string
