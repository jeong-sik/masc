(** Decoders for the async evidence of an activation and for a whole ledger.

    [of_projection_yojson] decodes the JSON form of a ledger: its fields, its
    activations, transition rejections and async evidence. It refuses a
    revision that does not match what it decoded. [async_evidence_of_yojson]
    decodes the async result deliveries and action observations of one
    activation. [validate_async_result] checks a delivery against the
    activations it names, and [validate_async_action] checks an action
    observation against its delivery. [exact_key_equal] says whether two
    activations share a skill tool use id.
    [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors
open Keeper_skill_activation_ledger_model

val exact_key_equal :
  activation ->
  activation -> bool

val validate_async_result :
  expected_trace_id:Keeper_id.Trace_id.t ->
  activations:activation list ->
  Keeper_skill_async_delivery.t ->
  (unit, decode_error) result

val validate_async_action :
  expected_trace_id:Keeper_id.Trace_id.t ->
  activations:activation list ->
  async_result_deliveries:Keeper_skill_async_delivery.t list ->
  async_actions:Keeper_skill_async_action.t list ->
  Keeper_skill_async_action.t ->
  (unit, decode_error) result

val async_evidence_of_yojson :
  expected_trace_id:Keeper_id.Trace_id.t -> activation:activation ->
  Yojson.Safe.t -> (async_evidence, decode_error) result

val of_projection_yojson : Yojson.Safe.t -> (t, decode_error) result
