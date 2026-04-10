(** Typed broadcast tool — Phase 1 PoC for compile-time tool safety.

    @since 2.260.0 *)

type broadcast_input = {
  message : string;
  format : string option;
}

type broadcast_output = {
  delivered : bool;
  room_message : string;
  mention : string option;
}

val parse_broadcast : Yojson.Safe.t -> (broadcast_input, string) result
val encode_broadcast : broadcast_output -> Yojson.Safe.t
val broadcast_params : Agent_sdk.Types.tool_param list
val handle_broadcast : broadcast_input -> (broadcast_output, string) result
val tool : (broadcast_input, broadcast_output) Typed_tool_masc.t
