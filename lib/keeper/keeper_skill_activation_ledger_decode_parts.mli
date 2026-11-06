(** Decoders for the parts of an activation, and the checks they share.

    [object_field], [string_field] and [int_field] read one field of a JSON
    object, and [exact_fields] refuses a duplicate or unexpected field.
    [decode_identity], [decode_instruction_origin],
    [decode_composition_origin], [decode_delivery], [decode_action_identity],
    [decode_action] and [decode_served_content] decode a skill identity, the
    two origins, a delivery, an action identity, an action and a served
    content. [action_identity_valid] says whether an action identity is well
    formed, and [delivery_boundary_turn] gives the turn of a delivery
    boundary. [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_errors

val action_identity_valid : Runtime_native_tools.action_identity -> bool

val object_field :
  string -> Yojson.Safe.t -> ((string * Yojson.Safe.t) list, decode_error) result

val string_field :
  string -> (string * Yojson.Safe.t) list -> (string, decode_error) result

val int_field :
  string -> (string * Yojson.Safe.t) list -> (int, decode_error) result

val exact_fields :
  object_name:string ->
  allowed:string list ->
  (string * 'a) list ->
  (unit, decode_error) result

val decode_identity :
  Yojson.Safe.t ->
  (Skill_reference.identity,
   decode_error)
  result

val decode_instruction_origin :
  Yojson.Safe.t ->
  (instruction_origin,
   decode_error)
  result

val decode_composition_origin :
  Yojson.Safe.t ->
  (composition_origin,
   decode_error)
  result

val delivery_boundary_turn :
  delivery_boundary -> int

val decode_delivery :
  Yojson.Safe.t ->
  (delivery option,
   decode_error)
  result

val decode_action_identity :
  Yojson.Safe.t ->
  (Runtime_native_tools.action_identity,
   decode_error)
  result

val decode_action :
  Yojson.Safe.t ->
  (action,
   decode_error)
  result

val decode_served_content :
  Yojson.Safe.t ->
  (served_content,
   decode_error)
  result
