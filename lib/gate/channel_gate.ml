(** Channel_gate -- deterministic router for external chat platforms.
    See [channel_gate.mli] for the full contract.

    This module owns structural validation and metrics recording.
    Types come from {!Gate_protocol}.
    Keeper dispatch is injected via [dispatch_fn]. *)

(* ── Re-exported types from Gate_protocol ────────────────────── *)

type inbound_message = Gate_protocol.inbound_message = {
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  keeper_name : string;
  content : string;
  idempotency_key : string;
  metadata : (string * string) list;
}

type turn_stats = Gate_protocol.turn_stats = {
  model_used : string;
  duration_ms : int;
  tokens_used : int;
}

type outbound_message = Gate_protocol.outbound_message = {
  keeper_name : string;
  content : string;
  structured : Yojson.Safe.t option;
  turn_stats : turn_stats option;
  message_request : Gate_protocol.message_request option;
}

type validation_error = Gate_protocol.validation_error =
  | Empty_content
  | Empty_keeper_name
  | Empty_channel_user_id
  | Empty_idempotency_key

type gate_error = Gate_protocol.gate_error =
  | Validation of validation_error
  | Keeper_error of string
  | Dispatch_unavailable
  | Internal of string

type dispatch_fn =
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result

type streaming_dispatch_fn =
  on_text_snapshot:(string -> unit) ->
  channel:string ->
  channel_user_id:string ->
  channel_user_name:string ->
  channel_workspace_id:string ->
  keeper_name:string ->
  idempotency_key:string ->
  metadata:(string * string) list ->
  content:string ->
  Gate_protocol.dispatch_result

(* ── Delegated helpers ───────────────────────────────────────── *)

let validation_error_to_string = Gate_protocol.validation_error_to_string
let gate_error_to_string = Gate_protocol.gate_error_to_string
let inbound_of_json = Gate_protocol.inbound_of_json
let outbound_to_json = Gate_protocol.outbound_to_json
let error_json = Gate_protocol.error_json

(* Validation *)

let validate (msg : inbound_message) = Gate_protocol.validate msg

(* ── Dispatch ────────────────────────────────────────────────── *)

let handle_inbound_with ~dispatch (msg : inbound_message) =
  let channel = msg.channel in
  match validate msg with
  | Error e ->
      Channel_gate_metrics.record_attempt
        ~channel
        ~workspace_id:msg.channel_workspace_id
        ~keeper:(String.trim msg.keeper_name)
        ~duration_ms:0
        (match e with
         | Empty_content
         | Empty_keeper_name
         | Empty_channel_user_id
         | Empty_idempotency_key ->
             Channel_gate_metrics.Validation_error
               (validation_error_to_string e));
      Error (Validation e)
  | Ok () ->
      let keeper = String.trim msg.keeper_name in
      let result =
        dispatch
          ~channel
          ~channel_user_id:msg.channel_user_id
          ~channel_user_name:msg.channel_user_name
          ~channel_workspace_id:msg.channel_workspace_id
          ~keeper_name:keeper
          ~idempotency_key:msg.idempotency_key
          ~metadata:msg.metadata
          ~content:(String.trim msg.content)
      in
      (match result with
       | Gate_protocol.Reply { content = reply; structured; stats; message_request } ->
           let duration_ms = match stats with
             | Some s -> s.duration_ms
             | None -> 0
           in
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms
             Channel_gate_metrics.Success;
           Ok
             { keeper_name = keeper
             ; content = reply
             ; structured
             ; turn_stats = stats
             ; message_request
             }
       | Gate_protocol.Keeper_error_result err ->
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms:0
             (Channel_gate_metrics.Keeper_error err);
           Error (Keeper_error err)
       | Gate_protocol.Unavailable_result ->
           Channel_gate_metrics.record_attempt
             ~channel
             ~workspace_id:msg.channel_workspace_id
             ~keeper
             ~duration_ms:0
             Channel_gate_metrics.Dispatch_unavailable;
           Error Dispatch_unavailable)

let handle_inbound ~dispatch msg =
  handle_inbound_with ~dispatch msg

let handle_inbound_streaming ~dispatch ~on_text_snapshot msg =
  handle_inbound_with ~dispatch:(dispatch ~on_text_snapshot) msg
