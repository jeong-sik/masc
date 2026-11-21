type 'rejection http_of = 'rejection Exact_lane_slot_visit.http =
  | Held
  | Rejected_before_dispatch of Agent_core.Exact_output.candidate_rejection_disposition
  | Execution_failed of Agent_core.Exact_output.execution_error_cause
  | Answer_rejected of 'rejection

type http = Librarian_answer.rejection http_of

type 'rejection cli_of = 'rejection Exact_lane_slot_visit.cli =
  | Cli_failed of Keeper_lane_cli_oneshot.failure
  | Cli_answer_rejected of 'rejection
  | Cli_seats_full
  | Cli_unservable

type cli = Librarian_answer.rejection cli_of

type 'rejection unanswered_of = 'rejection Exact_lane_slot_visit.unanswered =
  | Not_visited
  | Http of 'rejection http_of
  | Cli of 'rejection cli_of

type unanswered = Librarian_answer.rejection unanswered_of

type 'rejection t_of = 'rejection Exact_lane_slot_visit.t =
  | Answer_accepted
  | Unanswered of 'rejection unanswered_of

type t = Librarian_answer.rejection t_of

let bodies : Librarian_answer.rejection Exact_lane_slot_visit.bodies =
  { Exact_lane_slot_visit.empty_or_partial = Librarian_answer.Empty_or_partial
  ; not_json = Librarian_answer.Not_json
  }

let classify_unanswered : unanswered -> Librarian_slot_outcome.unanswered =
  Exact_lane_slot_visit.classify_unanswered bodies

let classify : t -> Librarian_slot_outcome.t = Exact_lane_slot_visit.classify bodies
