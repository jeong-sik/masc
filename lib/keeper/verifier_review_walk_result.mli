(** What a review walk leaves on its attempt when it ends without knowing one
    candidate's outcome.

    That walk empties its own retry list
    ({!Task.Anti_rationalization.review_result}), so its result alone no longer
    says which candidates failed in a way that passes with time. The
    classification the walk read for each failed candidate is retained here,
    beside the result. *)

type candidate =
  { runtime_id : string
  ; certainty : Task.Anti_rationalization.failure_certainty
  ; error_category : string
  ; failure : Task.Anti_rationalization.candidate_failure
  }

val certainty_label : Task.Anti_rationalization.failure_certainty -> string
(** The fact name a retained execution observation uses for this certainty. *)

val to_json : candidates:candidate list -> result:Yojson.Safe.t -> Yojson.Safe.t
(** Evidence of the attempt's [Execution_observed (Outcome_unknown _)] event.
    [candidates] are in the order the walk reported them; [result] is the
    walk's encoded review result. *)
