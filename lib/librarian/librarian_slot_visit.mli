(** What the walk of one ask saw at one slot, and the slot outcome it gives
    (RFC librarian-call-only-proposes §7.2).

    The types and the table are {!Exact_lane_slot_visit}'s, the ones every
    exact lane reads, with {!Librarian_answer.rejection} as the lane's
    rejection. Each constructor is documented there and is given again here
    under the same name: a type that takes the rejection is given again as
    its [_of] type, and the name without it is that type of the Librarian's
    rejection.

    The ask walks HTTP and CLI slots in one {!Exact_lane_slots.walk}. An HTTP
    slot's output and a CLI slot's JSON are read with
    {!Librarian_answer.of_json}, so a rejection reaches this module typed,
    as [Answer_rejected] or [Cli_answer_rejected]. *)

type 'rejection http_of = 'rejection Exact_lane_slot_visit.http =
  | Held
  | Rejected_before_dispatch of Agent_core.Exact_output.candidate_rejection_disposition
  | Execution_failed of Agent_core.Exact_output.execution_error_cause
  | Answer_rejected of 'rejection

(** What one HTTP slot did short of an answer. *)
type http = Librarian_answer.rejection http_of

type 'rejection cli_of = 'rejection Exact_lane_slot_visit.cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of 'rejection
  | Cli_seats_full
  | Cli_unservable

(** What one CLI slot did short of an answer. *)
type cli = Librarian_answer.rejection cli_of

type 'rejection unanswered_of = 'rejection Exact_lane_slot_visit.unanswered =
  | Not_visited
  | Http of 'rejection http_of
  | Cli of 'rejection cli_of

(** A slot the walk left without an answer. *)
type unanswered = Librarian_answer.rejection unanswered_of

type 'rejection t_of = 'rejection Exact_lane_slot_visit.t =
  | Answer_accepted
  | Unanswered of 'rejection unanswered_of

type t = Librarian_answer.rejection t_of

(** The Librarian's names for a body the table finds unusable before
    {!Librarian_answer.of_json} reads it: [Empty_or_partial] and
    [Not_json]. *)
val bodies : Librarian_answer.rejection Exact_lane_slot_visit.bodies

(** The outcome of a slot the walk left without an answer. An ask that no
    slot answered gives one of these for every slot. *)
val classify_unanswered : unanswered -> Librarian_slot_outcome.unanswered

(** [Answer_accepted] is [Slot_answered]; any other visit is its
    {!classify_unanswered}. *)
val classify : t -> Librarian_slot_outcome.t
