(** The rules that tie a row to the delivery that wrote it.

    [execution_id_of_fields] reads the [execution_id] of a stored row: [None]
    when the field is absent, [Error] when it is blank or not a string.
    [validate_delivery_execution_identity] checks that the execution id of a
    row agrees with the transcript slot of its delivery provenance. A
    [Tool_call] slot needs the same id and every other slot forbids one; a row
    without provenance passes.
    [validate_delivery_role] checks that the role of a row is the one its
    transcript slot allows: a user row for [Accepted_user], a system row for
    the approval slots, a tool row for the tool slots.
    [Keeper_chat_store] includes this module. *)

val execution_id_of_fields :
  (string * Yojson.Safe.t) list ->
  (Ids.Execution_id.t option, string) result

val validate_delivery_execution_identity :
  execution_id:Ids.Execution_id.t option ->
  Keeper_chat_delivery_identity.delivery_provenance option ->
  (unit, string) result

val validate_delivery_role :
  role_label:string ->
  Keeper_chat_delivery_identity.delivery_provenance -> (unit, string) result

val validate_delivery_slot_owner :
  Keeper_chat_delivery_identity.delivery_provenance -> (unit, string) result
(** Validate the owner/slot pair before reads that may authorize an append.
    Autonomous keys accept only their binding and common tool slots. *)

val validate_delivery_fields :
  provenance:Keeper_chat_delivery_identity.delivery_provenance ->
  (string * Yojson.Safe.t) list -> (unit, string) result
(** Shared row validation for strict readers, append candidates and the
    provenance index. Autonomous rows require their key's exact [turn_ref].
    Only System metadata may carry an autonomous input binding; its vector
    must be valid and its content empty. The binding slot belongs only to an
    autonomous key, which accepts only binding/tool slots. Other deliveries keep their
    existing role/execution rules. *)
