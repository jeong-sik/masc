(** In-flight join table from provider [tool_use_id] to the
    [execution_id] minted at the masc dispatch boundary (RFC-0233 PR-2).

    The keeper [post_tool_use] hook records the pair synchronously inside
    OAS tool execution, strictly before OAS publishes the matching
    [ToolCompleted] bus event; the event bridge only sees events after
    publish, so a [take] at serialization time is deterministic:
    insert happens-before publish happens-before drain.

    A missing entry is not an error — bus events from non-keeper agents
    (workers, evals) never get an entry because only keeper hooks mint
    execution ids. *)

val record : tool_use_id:string -> execution_id:string -> unit
(** Register an in-flight pair. An empty [tool_use_id] is ignored: the
    provider supplied no call id, so no event-side join is possible. *)

val take : tool_use_id:string -> string option
(** Look up and remove the pair. [None] means the event does not belong
    to a keeper execution (or the entry was already consumed). *)

module For_testing : sig
  val size : unit -> int
  val clear : unit -> unit
end
