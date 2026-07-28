(** Opaque durable identity for one OAS tool execution occurrence.

    Provider [tool_use_id] values are only unique within an OAS assistant tool
    batch. This value scopes one such ID with MASC's durable trace and, when
    available, the Keeper turn, plus OAS's own occurrence coordinates. It is
    serialized as one string because the approval journal already persists an
    opaque [tool_call_id]; consumers must not parse or reconstruct it. *)

type t

val create :
  trace_id:string ->
  ?keeper_turn_id:int ->
  Agent_sdk.Tool_contract.Invocation.t ->
  t

val to_string : t -> string
