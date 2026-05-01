open Base

(** Typed broadcast tool — Phase 1 PoC for compile-time tool safety.
    Schema and parse derived from {!Agent_sdk.Tool_schema_gen} combinators.

    @since 2.260.0 *)

type broadcast_output = {
  delivered : bool;
  room_message : string;
  mention : string option;
}

val broadcast_schema : string Agent_sdk.Tool_schema_gen.schema
val encode_broadcast : broadcast_output -> Yojson.Safe.t
val handle_broadcast : string -> (broadcast_output, string) Result.t
val tool : (string, broadcast_output) Typed_tool_masc.t
