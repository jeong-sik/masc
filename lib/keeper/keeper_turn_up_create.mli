(** Keeper_turn_up_create — create a new keeper from parsed arguments.

    Extracted from [keeper_turn_up.ml]'s [Ok None] branch. Handles
    initial keeper meta construction, checkpoint creation,
    keepalive start, and response JSON generation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Persist a freshly-built keeper_meta with field-merging CAS
    retry — preserves heartbeat-owned cursors when bootstrap races
    a supervisor write (#9749). *)
val write_initial_meta :
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  Keeper_lifecycle_nonce.create Keeper_lifecycle_nonce.witness ->
  Workspace.config ->
  keeper_meta ->
  (unit, string) result

(** Create a new keeper from parsed args: build initial meta,
    write checkpoint, start keepalive, return the [keeper_up]
    response envelope. *)
val create_keeper :
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  tool_result

module For_testing : sig
  val with_after_runtime_assignment :
    after_runtime_assignment:(unit -> unit) ->
    (unit -> 'a) ->
    'a
end
