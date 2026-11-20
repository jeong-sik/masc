(** What the walk of one ask saw at one slot, and the slot outcome it gives
    (RFC librarian-call-only-proposes §7.2).

    {!classify} reads each type a visit carries, from these four down to the
    Agent-Core and client errors, in one match per type without a wildcard. A
    constructor added to any of them stops the build until it has an outcome.
    The table of [test/fixtures/librarian_slot_outcome/] names one outcome
    per constructor, and its test runs every row through {!classify}. Text a value carries (a message, a stop reason sent as a
    string, a client's detail) is not read.

    The ask walks HTTP and CLI slots in one {!Exact_lane_slots.walk}. A CLI
    slot's JSON is read with {!Librarian_answer.of_json}, so its rejection
    reaches this module typed, as [Cli_answer_rejected]. *)

(** What one HTTP slot did short of an answer. *)
type http =
  | Held
  (** Not called: the walk's order holds the slot until a time its provider
      stated ({!Exact_lane_walk.walk}). *)
  | Rejected_before_dispatch of Agent_core.Exact_output.candidate_rejection_disposition
  (** The flow passed the slot without sending the question. *)
  | Execution_failed of Agent_core.Exact_output.execution_error_cause
  (** The attempt gave no structured output. *)
  | Answer_rejected of Librarian_answer.rejection
  (** The output came and {!Librarian_answer.of_json} refused it, so the
      flow advanced past the slot. *)

(** What one CLI slot did short of an answer. *)
type cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of Librarian_answer.rejection
  (** The client gave one JSON value and {!Librarian_answer.of_json}
      refused it. *)
  | Cli_seats_full
  (** Not called: every seat of the client's account was taken and a later
      slot gave a seat first. *)
  | Cli_unservable
  (** Not called: the question cannot be one prompt, or the client's
      account published no seats. *)

(** A slot the walk left without an answer. *)
type unanswered =
  | Not_visited (** The walk ended before the slot. *)
  | Http of http
  | Cli of cli

type t =
  | Answer_accepted
  (** An HTTP slot's output or a CLI slot's JSON value passed
      {!Librarian_answer.of_json}. *)
  | Unanswered of unanswered

(** The outcome of a slot the walk left without an answer. An ask that no
    slot answered gives one of these for every slot. *)
val classify_unanswered : unanswered -> Librarian_slot_outcome.unanswered

(** [Answer_accepted] is [Slot_answered]; any other visit is its
    {!classify_unanswered}. *)
val classify : t -> Librarian_slot_outcome.t
