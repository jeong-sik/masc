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

val all_of_candidate_decision : candidate_decision list
(** Every constructor, in the order the type declares them and the question
    lists them. The list is derived, so a constructor added later reaches the
    question without a second edit. *)

(** Question (b), asked once per turn without candidates: does the turn need
    stored knowledge at all. *)
type turn_need =
  | Needs_knowledge
  | Needs_no_knowledge
  | Unsure

val turn_need_label : turn_need -> string
val all_of_turn_need : turn_need list

(** Question (c), asked for the candidates question (a) carried: whether the
    memory holds a value tied to a moment (a number, a SHA, a head, a verdict,
    a progress state). *)
type time_nature =
  | Standing
  | Time_bound

val time_nature_label : time_nature -> string
val all_of_time_nature : time_nature list

(** A carried memory is [Marked] only when question (c) answered for it.
    [Time_unjudged] is never read as [Standing]. *)
type time_mark =
  | Marked of time_nature
  | Time_unjudged

(** {1 What one candidate got} *)

(** Why a candidate has no decision. [Capacity]: a request holding it was
    refused for size and no smaller request was left to try, or the purpose
    alone was refused for size and the request was never sent. [Too_large]: a
    request holding only this candidate was refused while question (b) was
    accepted. [Rate_limited]: every destination the request went to answered
    HTTP 429; a 429 mixed with another failure is [Provider_failed], the way
    the client takes a refusal for capacity only when every destination says
    so. [Provider_failed] covers every other failure of the request,
    a timeout among them: the client reports a timeout as text, so the reason
    cannot tell it from another transport failure. [Invalid_answer] covers a
    response that does not decode, and an answer that does not decode, is
    missing, or arrives in a response with duplicate or unknown ids. A
    cancelled request is not a reason: the cancellation is raised again and no
    status is built. *)
type unjudged_reason =
  | Capacity
  | Too_large
  | Rate_limited
  | Provider_failed
  | Invalid_answer

val all_of_unjudged_reason : unjudged_reason list

val unjudged_reason_token : unjudged_reason -> string
(** [capacity], [too_large], [rate_limited], [provider_failed],
    [invalid_answer]. *)

type candidate_result =
  | Decided of { id : string; decision : candidate_decision }
  | Undecided of { id : string; reason : unjudged_reason }

(** Whether question (b) produced an answer. A missing or invalid answer is
    [Turn_question_failed]; it is never replaced by [Unsure]. *)
type turn_answer =
  | Turn_answered of turn_need
  | Turn_question_failed

(** {1 What the turn gets} *)

(** How many of the candidates got a decision, out of all of them. *)
type coverage

(** A coverage in which at least one candidate got a decision. Every status
    that says candidates were judged carries this type, so such a status with
    no judged candidate cannot be built. *)
type judged_coverage

val coverage_judged : coverage -> int
val coverage_total : coverage -> int
val is_partial : coverage -> bool
(** [0 < judged && judged < total]: some candidates got a decision and some did
    not. The status line adds "M of N judged" when true. A coverage with no
    judged candidate is not partial: its status shows the reason and no count. *)

val widen_coverage : judged_coverage -> coverage

(** The carried candidates, in candidate order. Never empty. *)
type selection

val selection_ids : selection -> string list

(** Why the status is [Unavailable]. [Nothing_judged]: no candidate got a
    decision, so nothing was looked at; [reason] is the one of the first
    undecided candidate in candidate order, whatever question (b) said, and
    [total] counts the candidates. [Turn_unanswered]: candidates were judged,
    none was carried and question (b) produced no answer. Only {!reduce}
    builds one, so [total] is always the number of candidates. *)
type unavailable = private
  | Nothing_judged of { reason : unjudged_reason; total : int }
  | Turn_unanswered of judged_coverage

val unavailable_reason_token : unavailable -> string
(** The token the status line shows: [capacity], [rate_limited],
    [provider_failed], [invalid_answer] or [turn_question]. [Too_large] shows
    as [capacity]. *)

(** Only {!reduce} builds a status, so the selection, the counts and the
    reason always describe the same candidates. *)
type status = private
  | Selected of
      { selection : selection
      ; coverage : judged_coverage
      ; turn_question_contradicted : bool
        (** Question (b) answered [Needs_no_knowledge] while question (a)
            carried at least one candidate. The carried side wins and the
            evaluation record notes the contradiction. *)
      }
  | None_found of judged_coverage
  | None_needed of judged_coverage
  | Unavailable of unavailable

val status_token : status -> string
(** [selected], [none_found], [none_needed] or [unavailable]. *)

val status_coverage : status -> coverage
(** [Nothing_judged] has no judged candidate: its coverage is 0 of [total]. *)

val reduce : candidates:candidate_result list -> turn:turn_answer -> status option
(** [None] for no candidates: a Keeper without candidates has no judgment and
    no block. Otherwise:
    - a carried candidate gives [Selected], whatever question (b) said;
    - nothing decided gives [Unavailable (Nothing_judged _)] with the reason
      of the first undecided candidate in candidate order, whatever question
      (b) said;
    - decided candidates with none carried give [None_found] when question (b)
      answered [Needs_knowledge] or [Unsure], [None_needed] when it answered
      [Needs_no_knowledge], and [Unavailable (Turn_unanswered _)] when it
      failed. *)
