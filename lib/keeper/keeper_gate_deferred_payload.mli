(** Canonical non-blocking tool result for a durable Gate deferral.

    This module owns only the Gate receipt payload. The execution disposition
    is represented exclusively by {!Tool_result.Deferred}; payload fields and
    AGENT_CORE metadata are never semantic authorities. *)

type t

val create
  :  operation:string
  -> approval_id:string
  -> reason:Keeper_gate.deferred_reason
  -> audit_receipts:Keeper_approval.Audit.receipt list
  -> ?context:Yojson.Safe.t
  -> unit
  -> t

val data : t -> Yojson.Safe.t

(** Project the receipt as a canonical deferred Keeper execution. The external
    effect did not run and the Keeper remains free to continue other work. *)
val to_execution : t -> Keeper_tool_execution.t

val to_tool_result
  :  tool_name:string
  -> start_time:float
  -> t
  -> Tool_result.result
