(** Keeper_turn_up_create — create a new keeper from parsed arguments.

    Extracted from [keeper_turn_up.ml]'s [Ok None] branch. Handles
    initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val create_response_json :
  name:string ->
  trace_id:string ->
  instructions:string ->
  proactive_enabled:bool ->
  max_context_override:int option ->
  sandbox_profile:sandbox_profile ->
  network_mode:network_mode ->
  agent_core_env:(string * string) list ->
  Yojson.Safe.t
(** The envelope a successful create hands back.

    It names the isolation the keeper landed on. [network_mode] is a
    [keeper_up] argument; when the caller omits it the keeper takes its
    sandbox profile's default, and both [docker] and [microvm] default to
    [none]. This envelope is where the creating operator learns which of the
    two happened, so the two fields are part of the contract rather than
    decoration. *)

(** Create a new keeper from parsed args: build initial meta,
    write checkpoint, start keepalive, return the [keeper_up]
    response envelope. *)
val create_keeper :
  expected_config_revision:Keeper_turn_up_config_persistence.config_revision ->
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  tool_result
