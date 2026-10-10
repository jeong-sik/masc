(** Ordered host publication of worker notices. Recording is synchronous and
    never publishes; call it while the worker RPC serialization is held. *)
type batch
val create : author:string -> relay:(author:string -> string -> unit) -> batch
val record : batch -> Mcp_protocol.Mcp_types.tool_result -> unit
val ready : batch -> unit
(** Mark ready only after releasing the credential transaction. *)
val drain : unit -> unit
(** Stops at the first unready notice, preserving machine-effect order. *)
