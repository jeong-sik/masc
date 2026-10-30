(** Frozen worker generation and schema. Values own no worker resources;
    invocation still revalidates the live connection, schema and caller access. *)
type owner
val create_owner : instance_id:string -> owner
(** Fresh identity for one host worker start, shared by its created/ready
    connection wrappers. Equal instance strings do not make equal owners. *)
val equal_owner : owner -> owner -> bool

type t = private
  { owner : owner; instance_id : string; tool : Mcp_protocol.Mcp_types.tool }
val create : owner:owner -> tool:Mcp_protocol.Mcp_types.tool -> t
(** Reuse the same export under the exact owner and Tool objects. Weak keys
    retain it only while those inputs are owned; no temporary wrapper identity,
    schema/name equality or cached execution result grants reuse. *)

type conflict_reason = Reserved_host_name | Multiple_installations
type conflict = { name : string; instances : string list; reason : conflict_reason }
type snapshot = { exports : t list; conflicts : conflict list }
val isolate : reserved:string list -> t list -> snapshot
(** Omit every export of a conflicting name, retaining unrelated exports and
    typed diagnostics. A reserved host descriptor is never removed. *)
val conflict_to_string : conflict -> string
