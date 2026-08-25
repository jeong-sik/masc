(** In-flight join table from an exact Agent Core invocation to the
    [execution_id] minted at the masc dispatch boundary (RFC-0233 PR-2).

    The keeper [post_tool_use] hook records the pair synchronously inside
    AGENT_CORE tool execution, strictly before AGENT_CORE publishes the matching
    [ToolCompleted] bus event; the event bridge only sees events after
    publish, so a [take] at serialization time is deterministic:
    insert happens-before publish happens-before drain.

    Invocation keys are weak and physically identified. The hook and event bus
    carry the same immutable invocation value, while a cancelled publication
    cannot leave the invocation alive through this table. Blank or repeated
    provider tool-use ids therefore remain distinct occurrences.

    A missing entry is not an error — bus events from non-keeper agents
    (workers, evals) never get an entry because only keeper hooks mint
    execution ids. *)

val record :
  invocation:Agent_core.Tool_contract.Invocation.t -> execution_id:string -> unit
(** Register the exact invocation/execution pair. *)

val take : invocation:Agent_core.Tool_contract.Invocation.t -> string option
(** Look up and remove the pair. [None] means the event does not belong
    to a keeper execution (or the entry was already consumed). *)

module For_testing : sig
  val size : unit -> int
  val clear : unit -> unit
end
