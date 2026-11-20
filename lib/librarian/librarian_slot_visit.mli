(** What the walk of one ask saw at one slot, and the slot outcome it gives
    (RFC librarian-call-only-proposes §7.2).

    {!classify} reads each type a visit carries, from these three down to the
    Agent-Core and client errors, in one match per type without a wildcard. A
    constructor added to any of them stops the build until it has an outcome.
    The table of [test/fixtures/librarian_slot_outcome/] names one outcome
    per constructor, and its test runs every row through {!classify}. Text a value carries (a message, a stop reason sent as a
    string, a client's detail) is not read.

    A CLI slot is run with {!Keeper_lane_cli_oneshot.run} and its JSON read
    with {!Librarian_answer.of_json}, not walked with
    {!Keeper_lane_cli_oneshot.walk}: [walk]'s [validate] returns a rejection
    as a string, so a {!Librarian_answer.rejection} would reach this module
    only as the text of [Invalid_domain_output]. *)

(** What one HTTP slot did. *)
type http =
  | Held
  (** Not called: {!Runtime_exact_lane_backpressure.order} holds the slot
      until a time its provider stated. *)
  | Rejected_before_dispatch of Agent_core.Exact_output.candidate_rejection_disposition
  (** The flow passed the slot without sending the question. *)
  | Execution_failed of Agent_core.Exact_output.execution_error_cause
  (** The attempt gave no structured output. *)
  | Answer_rejected of Librarian_answer.rejection
  (** The output came and {!Librarian_answer.of_json} refused it, so the
      flow advanced past the slot. *)
  | Answer_accepted

(** What one CLI slot did. *)
type cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of Librarian_answer.rejection
  (** The client gave one JSON value and {!Librarian_answer.of_json}
      refused it. *)
  | Cli_answer_accepted

type t =
  | Not_visited (** The walk ended before the slot. *)
  | Http of http
  | Cli of cli

val classify : t -> Librarian_slot_outcome.t
