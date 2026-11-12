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

val cancelled : Yojson.Safe.t
(** Evidence of the [Execution_observed (Outcome_unknown _)] event a cancelled
    review leaves on its attempt. It is not a walk result. *)

(** What the attempt's walk left among its execution observations. *)
type reading =
  | No_walk_result
      (** The walk was cut before it retained a result: the review was
          cancelled, or its process ended. *)
  | Walk_result of
      { candidates : candidate list
      ; result : Yojson.Safe.t
      }
      (** The value {!to_json} wrote. *)

val read : Lane_addon_request_progress.t -> (reading, string) result
(** Every event is read, so a cancellation recorded after the walk result does
    not hide it. More than one walk result, and an unknown-outcome observation
    that is neither {!cancelled} nor the value {!to_json} wrote, are errors. *)
