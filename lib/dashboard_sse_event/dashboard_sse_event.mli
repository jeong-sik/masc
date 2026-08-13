(** Closed event vocabulary for dashboard SSE producers migrated to the typed
    broadcast boundary.

    This first slice covers the HITL approval lifecycle. Add a constructor and
    its exhaustive [to_string] arm before a new wire event can compile. *)
type t =
  | Approval_pending
  | Approval_resolved
  | Approval_audit
  | Approval_summary_updated

val to_string : t -> string

(** [encode event ~payload] is the pure JSON boundary. Effectful broadcasting
    stays in the caller so retry/cancellation policy remains visible there. *)
val encode : t -> payload:Yojson.Safe.t -> Yojson.Safe.t
