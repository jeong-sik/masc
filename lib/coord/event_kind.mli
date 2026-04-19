(** Event_kind — Compile-time verified event-kind identifiers.

    Event-kind strings such as task.claimed and board.voted flow
    between emitters (coord, board, keeper) and consumers
    (activity_graph_reducer, tool_agent_timeline, dashboard). Prior to
    this module both sides used raw [string]; a typo on either side
    compiled clean and silently diverged at runtime.

    This module is the SSOT for the task.* and message.* families.
    Other families (board.*, agent.*, keeper.*, ...) are tracked in
    issue 8455 and will be migrated in follow-up PRs on the same
    pattern.

    Parse boundary: {!Task.of_string} at JSONL / wire ingress only;
    internal code uses [Task.t] directly so typos become compile
    errors. *)

module Task : sig
  type t =
    | Created
    | Claimed
    | Started
    | Released
    | Done
    | Cancelled
    | Submit_for_verification
    | Approved
    | Rejected
    | Linked

  val to_string : t -> string
  (** Canonical dotted-form wire name ([task.claimed] etc.). *)

  val of_string : string -> t option
  (** Inverse of {!to_string}. Returns [None] for unknown inputs so
      consumers can opt between fail-closed and fail-open. *)

  val all : t list
  (** Exhaustive enumeration; useful for tests that want to assert
      every variant round-trips through JSON. *)
end

module Message : sig
  type t =
    | Broadcast
    | Mentioned

  val to_string : t -> string
  (** Canonical dotted-form wire name (e.g. [message.broadcast]). *)

  val of_string : string -> t option
  val all : t list
end
