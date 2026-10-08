(** Immutable worker incarnation and schema, independent of runtime ownership.
    Possession is not authority: invocation revalidates live state and access. *)
type t = private { instance_id : string; tool : Mcp_protocol.Mcp_types.tool }
val create : instance_id:string -> tool:Mcp_protocol.Mcp_types.tool -> t
