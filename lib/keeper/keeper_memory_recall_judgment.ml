type candidate_decision =
  | Possibly_needed
  | Not_needed

let candidate_decision_label = function
  | Possibly_needed -> "possibly_needed"
  | Not_needed -> "not_needed"

let all_candidate_decisions = [Possibly_needed; Not_needed]

type turn_need =
  | Needs_knowledge
  | Needs_no_knowledge
  | Unsure

let turn_need_label = function
  | Needs_knowledge -> "yes"
  | Needs_no_knowledge -> "no"
  | Unsure -> "unsure"

let all_turn_needs = [Needs_knowledge; Needs_no_knowledge; Unsure]

type time_nature =
  | Standing
  | Time_bound

let time_nature_label = function
  | Standing -> "standing"
  | Time_bound -> "time_bound"

let all_time_natures = [Standing; Time_bound]

type time_mark =
  | Marked of time_nature
  | Time_unjudged

type unjudged_reason =
  | Capacity
  | Too_large
  | Rate_limited
  | Timeout
  | Provider_failed
  | Cancelled
  | Invalid_answer

let unjudged_reason_token = function
  | Capacity -> "capacity"
  | Too_large -> "too_large"
  | Rate_limited -> "rate_limited"
  | Timeout -> "timeout"
  | Provider_failed -> "provider_failed"
  | Cancelled -> "cancelled"
  | Invalid_answer -> "invalid_answer"

type candidate_result =
  | Decided of { id : string; decision : candidate_decision }
  | Undecided of { id : string; reason : unjudged_reason }

type turn_answer =
  | Turn_answered of turn_need
  | Turn_question_failed

type unavailable_reason =
  | Candidates_unjudged of unjudged_reason
  | Turn_question

let unavailable_reason_token = function
  | Candidates_unjudged Too_large -> "capacity"
  | Candidates_unjudged
      ((Capacity | Rate_limited | Timeout | Provider_failed | Cancelled
       | Invalid_answer) as reason) -> unjudged_reason_token reason
  | Turn_question -> "turn_question"

type coverage = { judged : int; total : int }
type judged_coverage = coverage
type selection = { first : string; rest : string list }

let coverage_judged { judged; total = _ } = judged
let coverage_total { judged = _; total } = total
let is_partial { judged; total } = judged < total
let widen_coverage (coverage : judged_coverage) : coverage = coverage
let selection_ids { first; rest } = first :: rest

type status =
  | Selected of { selection : selection; coverage : judged_coverage }
  | None_found of judged_coverage
  | None_needed of judged_coverage
  | Unavailable of { reason : unavailable_reason; coverage : coverage }

let status_token = function
  | Selected _ -> "selected"
  | None_found _ -> "none_found"
  | None_needed _ -> "none_needed"
  | Unavailable _ -> "unavailable"

let status_coverage = function
  | Selected { coverage; selection = _ } -> widen_coverage coverage
  | None_found coverage | None_needed coverage -> widen_coverage coverage
  | Unavailable { coverage; reason = _ } -> coverage

type verdict = { status : status; turn_question_contradicted : bool }

(* The accumulator has one case per final shape, so the coverage of a
   "judged" status is built from at least one decided candidate and the
   all-undecided case always has a reason to report. *)
type accumulator =
  | Nothing_decided of { total : int; first_reason : unjudged_reason }
  | Some_decided of { judged : int; total : int; carried_rev : string list }

let carry id = function
  | Possibly_needed -> [id]
  | Not_needed -> []

let start = function
  | Decided { id; decision } ->
    Some_decided { judged = 1; total = 1; carried_rev = carry id decision }
  | Undecided { reason; id = _ } ->
    Nothing_decided { total = 1; first_reason = reason }

let step accumulator result =
  match accumulator, result with
  | Nothing_decided { total; first_reason }, Undecided { reason = _; id = _ } ->
    Nothing_decided { total = total + 1; first_reason }
  | Nothing_decided { total; first_reason = _ }, Decided { id; decision } ->
    Some_decided { judged = 1; total = total + 1; carried_rev = carry id decision }
  | Some_decided { judged; total; carried_rev }, Undecided { reason = _; id = _ } ->
    Some_decided { judged; total = total + 1; carried_rev }
  | Some_decided { judged; total; carried_rev }, Decided { id; decision } ->
    Some_decided
      { judged = judged + 1
      ; total = total + 1
      ; carried_rev = carry id decision @ carried_rev
      }

let verdict status ~contradicted = { status; turn_question_contradicted = contradicted }

let finish accumulator ~turn =
  match accumulator with
  | Nothing_decided { total; first_reason } ->
    verdict ~contradicted:false
      (Unavailable
         { reason = Candidates_unjudged first_reason
         ; coverage = { judged = 0; total }
         })
  | Some_decided { judged; total; carried_rev } ->
    let coverage = { judged; total } in
    (match List.rev carried_rev, turn with
     | first :: rest, Turn_answered Needs_no_knowledge ->
       verdict ~contradicted:true
         (Selected { selection = { first; rest }; coverage })
     | first :: rest, (Turn_answered (Needs_knowledge | Unsure) | Turn_question_failed) ->
       verdict ~contradicted:false
         (Selected { selection = { first; rest }; coverage })
     | [], Turn_answered (Needs_knowledge | Unsure) ->
       verdict ~contradicted:false (None_found coverage)
     | [], Turn_answered Needs_no_knowledge ->
       verdict ~contradicted:false (None_needed coverage)
     | [], Turn_question_failed ->
       verdict ~contradicted:false
         (Unavailable { reason = Turn_question; coverage }))

let reduce ~candidates ~turn =
  match candidates with
  | [] -> None
  | first :: rest -> Some (finish (List.fold_left step (start first) rest) ~turn)
