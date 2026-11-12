module AR = Task.Anti_rationalization

type candidate =
  { runtime_id : string
  ; certainty : AR.failure_certainty
  ; error_category : string
  ; failure : AR.candidate_failure
  }

let schema = "verifier_review_unknown/v2"

let certainty_label = function
  | AR.Before_dispatch -> "before_dispatch"
  | Definite_refusal -> "definite_refusal"
  | Outcome_unknown -> "outcome_unknown"

let failure_label = function
  | AR.Reviews_again -> "reviews_again"
  | Model_absent -> "model_absent"
  | Producer_must_act -> "producer_must_act"

let candidate_to_json { runtime_id; certainty; error_category; failure } =
  `Assoc
    [ "runtime_id", `String runtime_id
    ; "certainty", `String (certainty_label certainty)
    ; "error_category", `String error_category
    ; "failure", `String (failure_label failure)
    ]

let to_json ~candidates ~result =
  `Assoc
    [ "schema", `String schema
    ; "candidate_failures", `List (List.map candidate_to_json candidates)
    ; "result", result
    ]
