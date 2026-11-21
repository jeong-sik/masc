(** What a walk saw at one slot of an exact lane, and the slot outcome it
    gives (RFC curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside
    §4.7, RFC librarian-call-only-proposes §7.2).

    {!classify} reads each type a visit carries, from these four down to the
    Agent-Core and client errors, in one match per type without a wildcard. A
    constructor added to any of them stops the build until it has an outcome.
    The table of [test/fixtures/librarian_slot_outcome/] names one outcome
    per constructor, and its test runs every row through {!classify}. Text a
    value carries (a message, a stop reason sent as a string, a client's
    detail) is not read.

    Every lane that walks with {!Exact_lane_slots.walk} reads this one table,
    so a refusal means the same to each. ['rejection] is why the lane's own
    check refused a body that came; a lane gives its type and the two values
    of {!bodies}. *)

(** What one HTTP slot did short of an answer. *)
type 'rejection http =
  | Held
  (** Not called: the walk's order holds the slot until a time its provider
      stated ({!Exact_lane_walk.walk}). *)
  | Rejected_before_dispatch of Agent_core.Exact_output.candidate_rejection_disposition
  (** The flow passed the slot without sending the request. *)
  | Execution_failed of Agent_core.Exact_output.execution_error_cause
  (** The attempt gave no structured output. *)
  | Answer_rejected of 'rejection
  (** The output came and the lane's check refused it, so the flow advanced
      past the slot. *)

(** What one CLI slot did short of an answer. *)
type 'rejection cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of 'rejection
  (** The client gave one JSON value and the lane's check refused it. *)
  | Cli_seats_full
  (** Not called: every seat of the client's account was taken and a later
      slot gave a seat first. *)
  | Cli_unservable
  (** Not called: the request cannot be one prompt, or the client's account
      published no seats. *)

(** A slot the walk left without an answer. *)
type 'rejection unanswered =
  | Not_visited (** The walk ended before the slot. *)
  | Http of 'rejection http
  | Cli of 'rejection cli

type 'rejection t =
  | Answer_accepted
  (** An HTTP slot's output or a CLI slot's JSON value passed the lane's
      check. *)
  | Unanswered of 'rejection unanswered

(** The lane's names for a body the table itself finds unusable, before the
    lane's check reads it. The table cannot make a lane's rejection, so the
    lane gives the two it needs. *)
type 'rejection bodies =
  { empty_or_partial : 'rejection
  (** No output, or one that stopped before its end. *)
  ; not_json : 'rejection (** The output is not one JSON value. *)
  }

(** The outcome of a slot the walk left without an answer. A walk that no
    slot answered gives one of these for every slot. *)
val classify_unanswered
  :  'rejection bodies
  -> 'rejection unanswered
  -> 'rejection Exact_lane_slot_outcome.unanswered

(** [Answer_accepted] is [Slot_answered]; any other visit is its
    {!classify_unanswered}. *)
val classify : 'rejection bodies -> 'rejection t -> 'rejection Exact_lane_slot_outcome.t

(** One slot a walk passed, with the id its lane declares it by: an HTTP
    slot's id, or a CLI slot's runtime id. *)
type 'rejection slot_visit =
  | Http_visit of (string * 'rejection http)
  | Cli_visit of (string * 'rejection cli)

(** What {!Exact_lane_slots.walk} left at one slot it passed. Each HTTP slot
    is a flow of one candidate, so its failure names that slot.

    [Error] is a flow that ended on masc's own failure: a replayed flow, an
    identity it could not allocate, or a callback of the lane. The walk
    stops on those ([Exact_lane_slots.Http_stopped]), so no passed slot
    holds one; the type does not say so, and the lane ends as it does for a
    stopped walk. *)
val of_passed
  :  ( Exact_lane_slots.t
       , ('rejection, 'record_error) Exact_lane_slots.failure )
       Exact_lane_walk.passed
  -> ('rejection slot_visit, 'record_error Agent_core.Exact_output.flow_execution_error) result
