(** The JSON form of a ledger and of its parts, and the hashes taken over
    them.

    [schema] is the schema name of the form. [delivery_to_yojson],
    [action_to_yojson], [transition_rejection_to_yojson] and
    [activation_to_yojson] render the parts of a ledger, and [to_yojson]
    renders the ledger with its schema and [revision]. [recorded_part] is what
    an activation records when it is made, without the delivery and actions
    that arrive later; [activation_frame_to_yojson] renders it and
    [activation_frame_sha256] hashes it.
    [async_evidence_for_activation] selects the async result deliveries that
    name an activation by its skill tool use id and frame hash, and the action
    observations of those deliveries. [revision] is the SHA-256 of the whole
    canonical ledger, kept with the value after the first read, and
    [receipt_projection_revision] hashes it together with a skill tool use
    id. [Keeper_skill_activation_ledger] includes this module. *)

open Keeper_skill_activation_types
open Keeper_skill_activation_ledger_model

val schema : string

val delivery_to_yojson :
  delivery ->
  Yojson.Safe.t

val action_to_yojson :
  action ->
  Yojson.Safe.t

val transition_rejection_to_yojson :
  transition_rejection ->
  Yojson.Safe.t

val activation_to_yojson : activation -> Yojson.Safe.t

val recorded_part :
  activation ->
  activation

val activation_frame_to_yojson : activation -> Yojson.Safe.t

val activation_frame_sha256 : activation -> string

val async_evidence_for_activation : t -> activation -> async_evidence

val revision : t -> ledger_revision

val receipt_projection_revision : t -> skill_tool_use_id:string -> string

val to_yojson : t -> Yojson.Safe.t
