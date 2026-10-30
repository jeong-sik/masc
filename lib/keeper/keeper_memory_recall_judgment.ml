type candidate_decision =
  | Possibly_needed
  | Not_needed
[@@deriving enumerate]

let candidate_decision_label = function
  | Possibly_needed -> "possibly_needed"
  | Not_needed -> "not_needed"

type turn_need =
  | Needs_knowledge
  | Needs_no_knowledge
  | Unsure
[@@deriving enumerate]

let turn_need_label = function
  | Needs_knowledge -> "yes"
  | Needs_no_knowledge -> "no"
  | Unsure -> "unsure"

type time_nature =
  | Standing
  | Time_bound
[@@deriving enumerate]

let time_nature_label = function
  | Standing -> "standing"
  | Time_bound -> "time_bound"

type time_mark =
  | Marked of time_nature
  | Time_unjudged

type unjudged_reason =
  | Capacity
  | Too_large
  | Rate_limited
  | Provider_failed
  | Invalid_answer
  | Not_recorded
[@@deriving enumerate]

let unjudged_reason_token = function
  | Capacity -> "capacity"
  | Too_large -> "too_large"
  | Rate_limited -> "rate_limited"
  | Provider_failed -> "provider_failed"
  | Invalid_answer -> "invalid_answer"
  | Not_recorded -> "not_recorded"

type candidate_result =
  | Decided of { id : string; decision : candidate_decision }
  | Undecided of { id : string; reason : unjudged_reason }

type turn_answer =
  | Turn_answered of turn_need
  | Turn_question_failed

type coverage = { judged : int; total : int }
type judged_coverage = coverage
type selection = { first : string; rest : string list }

let coverage_judged { judged; total = _ } = judged
let coverage_total { judged = _; total } = total
let is_partial { judged; total } = 0 < judged && judged < total
let widen_coverage (coverage : judged_coverage) : coverage = coverage
let selection_ids { first; rest } = first :: rest

type unavailable =
  | Nothing_judged of { reason : unjudged_reason; total : int }
  | Turn_unanswered of judged_coverage

let unavailable_reason_token = function
  | Nothing_judged { reason = Too_large; total = _ } -> "capacity"
  | Nothing_judged
      { reason = (Capacity | Rate_limited | Provider_failed | Invalid_answer | Not_recorded) as reason
      ; total = _
      } -> unjudged_reason_token reason
  | Turn_unanswered _ -> "turn_question"

type status =
  | Selected of
      { selection : selection
      ; coverage : judged_coverage
      ; turn_question_contradicted : bool
      }
  | None_found of judged_coverage
  | None_needed of judged_coverage
  | Unavailable of unavailable

let status_token = function
  | Selected _ -> "selected"
  | None_found _ -> "none_found"
  | None_needed _ -> "none_needed"
  | Unavailable _ -> "unavailable"

let status_coverage = function
  | Selected { coverage; selection = _; turn_question_contradicted = _ } ->
    widen_coverage coverage
  | None_found coverage | None_needed coverage -> widen_coverage coverage
  | Unavailable (Turn_unanswered coverage) -> widen_coverage coverage
  | Unavailable (Nothing_judged { total; reason = _ }) -> { judged = 0; total }

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

let finish accumulator ~turn =
  match accumulator with
  | Nothing_decided { total; first_reason } ->
    Unavailable (Nothing_judged { reason = first_reason; total })
  | Some_decided { judged; total; carried_rev } ->
    let coverage = { judged; total } in
    (match List.rev carried_rev, turn with
     | first :: rest, Turn_answered Needs_no_knowledge ->
       Selected
         { selection = { first; rest }; coverage; turn_question_contradicted = true }
     | first :: rest, (Turn_answered (Needs_knowledge | Unsure) | Turn_question_failed) ->
       Selected
         { selection = { first; rest }; coverage; turn_question_contradicted = false }
     | [], Turn_answered (Needs_knowledge | Unsure) -> None_found coverage
     | [], Turn_answered Needs_no_knowledge -> None_needed coverage
     | [], Turn_question_failed -> Unavailable (Turn_unanswered coverage))

let reduce ~candidates ~turn =
  match candidates with
  | [] -> None
  | first :: rest -> Some (finish (List.fold_left step (start first) rest) ~turn)
