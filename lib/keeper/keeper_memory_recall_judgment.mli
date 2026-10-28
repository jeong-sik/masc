(** Closed vocabulary and reduction rule of Keeper memory recall
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, sections 4.3 and 4.4).

    Nothing here depends on the TypeSafe client. A judgment made by Jev in the
    run path and one made by a re-judging model offline use the same types.
    Nothing here sends, stores or renders anything. *)

(** {1 What a model answers} *)

(** Question (a), asked once per candidate memory. [Possibly_needed] covers
    both "the turn may use it" and "unclear". There is no middle label and no
    score: a candidate is either carried or left out. *)
type candidate_decision =
  | Possibly_needed
  | Not_needed

val candidate_decision_label : candidate_decision -> string
(** The label the question offers and the answer returns. *)

val all_candidate_decisions : candidate_decision list
(** In the order the question lists them. *)

(** Question (b), asked once per turn without candidates: does the turn need
    stored knowledge at all. *)
type turn_need =
  | Needs_knowledge
  | Needs_no_knowledge
  | Unsure

val turn_need_label : turn_need -> string
val all_turn_needs : turn_need list

(** Question (c), asked for the candidates question (a) carried: whether the
    memory holds a value tied to a moment (a number, a SHA, a head, a verdict,
    a progress state). *)
type time_nature =
  | Standing
  | Time_bound

val time_nature_label : time_nature -> string
val all_time_natures : time_nature list

(** A carried memory is [Marked] only when question (c) answered for it.
    [Time_unjudged] is never read as [Standing]. *)
type time_mark =
  | Marked of time_nature
  | Time_unjudged

(** {1 What one candidate got} *)

(** Why a candidate has no decision. [Capacity]: a request holding it was
    refused for size and no smaller request was left to try. [Too_large]: a
    request holding only this candidate was refused while question (b) was
    accepted. [Invalid_answer] covers an answer that does not decode, an
    answer that is missing, and a response with duplicate or unknown ids. *)
type unjudged_reason =
  | Capacity
  | Too_large
  | Rate_limited
  | Timeout
  | Provider_failed
  | Cancelled
  | Invalid_answer

val unjudged_reason_token : unjudged_reason -> string
(** [capacity], [too_large], [rate_limited], [timeout], [provider_failed],
    [cancelled], [invalid_answer]. *)

type candidate_result =
  | Decided of { id : string; decision : candidate_decision }
  | Undecided of { id : string; reason : unjudged_reason }

(** Whether question (b) produced an answer. A missing or invalid answer is
    [Turn_question_failed]; it is never replaced by [Unsure]. *)
type turn_answer =
  | Turn_answered of turn_need
  | Turn_question_failed

(** {1 What the turn gets} *)

(** Why nothing was judged or the turn could not be settled. *)
type unavailable_reason =
  | Candidates_unjudged of unjudged_reason
  | Turn_question

val unavailable_reason_token : unavailable_reason -> string
(** The token the status line shows: [capacity], [rate_limited], [timeout],
    [provider_failed], [cancelled], [invalid_answer] or [turn_question].
    [Too_large] shows as [capacity]. *)

(** How many of the candidates got a decision, out of all of them. *)
type coverage

(** A coverage in which at least one candidate got a decision. Only
    [Selected], [None_found] and [None_needed] carry this type, so a
    "judged and found nothing" status with no judged candidate cannot be
    built. *)
type judged_coverage

val coverage_judged : coverage -> int
val coverage_total : coverage -> int
val is_partial : coverage -> bool
(** [judged < total]. The status line adds "M of N judged" when true. *)

val widen_coverage : judged_coverage -> coverage

(** The carried candidates, in candidate order. Never empty. *)
type selection

val selection_ids : selection -> string list

type status =
  | Selected of { selection : selection; coverage : judged_coverage }
  | None_found of judged_coverage
  | None_needed of judged_coverage
  | Unavailable of { reason : unavailable_reason; coverage : coverage }

val status_token : status -> string
(** [selected], [none_found], [none_needed] or [unavailable]. *)

val status_coverage : status -> coverage

type verdict =
  { status : status
  ; turn_question_contradicted : bool
        (** Question (b) answered [Needs_no_knowledge] while question (a)
            carried at least one candidate. The carried side wins and the
            evaluation record notes the contradiction. *)
  }

val reduce : candidates:candidate_result list -> turn:turn_answer -> verdict option
(** [None] for no candidates: a Keeper without candidates has no judgment and
    no block. Otherwise:
    - a carried candidate gives [Selected], whatever question (b) said;
    - nothing decided gives [Unavailable] with the reason of the first
      undecided candidate in candidate order, whatever question (b) said;
    - decided candidates with none carried give [None_found] when question (b)
      answered [Needs_knowledge] or [Unsure], [None_needed] when it answered
      [Needs_no_knowledge], and [Unavailable Turn_question] when it failed. *)
