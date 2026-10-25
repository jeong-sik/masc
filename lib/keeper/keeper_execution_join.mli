(** Product identity for tool observations. Durable invocations cite the exact
    canonical node directly and need no live object-reference join. Explicit
    non-journalled invocations retain a weak, in-flight product association.
    These values never authorize execution or recovery. *)

val record :
  invocation:Agent_core.Tool_contract.Invocation.t -> execution_id:string -> unit
(** Record a non-journalled invocation/execution pair; canonical identity is already fixed. *)

val discard : invocation:Agent_core.Tool_contract.Invocation.t -> unit
(** Remove the exact invocation without publishing its execution identity.
    Canonical occurrence identity is an immutable fact and is not withdrawn
    when a product projection fails. A missing transient entry is ignored. *)

val peek : invocation:Agent_core.Tool_contract.Invocation.t -> string option
(** Read without consuming, inside the post-tool hook after the log commits
    and before ToolCompleted is published. *)

val take : invocation:Agent_core.Tool_contract.Invocation.t -> string option
(** Return the canonical node identity, or consume the transient pair.
    [None] means a non-journalled event has no retained product association. *)

module For_testing : sig
  val size : unit -> int
  val clear : unit -> unit
end
