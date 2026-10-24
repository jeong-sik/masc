(** Per-native-execution response evidence inherited by its tool fibers.
    This is an execution-local carrier, never a worker-name registry. *)
val with_scope :
  actor:string option -> runtime_id:string -> provider_id:string option ->
  (hooks:Agent_core.Hooks.hooks -> wrap_tool:(Agent_core.Tool.t -> Agent_core.Tool.t) -> 'a) -> 'a
(** A fresh execution identity and empty response are installed for the whole
    call. Its hooks clear the prior response at BeforeTurn and capture the
    authoritative AfterTurn response before tool dispatch. [wrap_tool] freezes
    that response with the exact invocation for each handler (including its
    resource-scoped handler). Missing provider, model or invocation evidence
    keeps the response unobserved. *)

val current : unit -> Runtime_response_identity.t option
(** Copy of the current native response's immutable identity. Absent outside
    a captured execution; no process-global or metadata fallback exists. *)

val without_identity : (unit -> 'a) -> 'a
(** Mask an invoking tool's identity while dispatching a different runtime.
    An uncaptured official-client execution must not borrow its caller's. *)
