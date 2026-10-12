(** Immutable worker incarnation and schema, independent of runtime ownership.
    Possession is not authority: invocation revalidates live state and access. *)
type t = private { instance_id : string; tool : Mcp_protocol.Mcp_types.tool }
val create : instance_id:string -> tool:Mcp_protocol.Mcp_types.tool -> t

type conflict_reason = Reserved_host_name | Multiple_installations
type conflict = { name : string; instances : string list; reason : conflict_reason }
type snapshot = { exports : t list; conflicts : conflict list }
val isolate : reserved:string list -> t list -> snapshot
(** Omit every export of a conflicting name, retaining unrelated exports and
    typed diagnostics. A reserved host descriptor is never removed. *)
val conflict_to_string : conflict -> string
