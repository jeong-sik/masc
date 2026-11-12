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

let cancelled = `Assoc [ "cause", `String "review_cancelled" ]

type reading =
  | No_walk_result
  | Walk_result of
      { candidates : candidate list
      ; result : Yojson.Safe.t
      }

let certainty_of_label label =
  List.find_opt
    (fun certainty -> String.equal (certainty_label certainty) label)
    [ AR.Before_dispatch; Definite_refusal; Outcome_unknown ]

let failure_of_label label =
  List.find_opt
    (fun failure -> String.equal (failure_label failure) label)
    [ AR.Reviews_again; Model_absent; Producer_must_act ]

let candidate_of_json json =
  let malformed = Error "walk result candidate is malformed" in
  match json with
  | `Assoc fields
    when List.sort String.compare (List.map fst fields)
         = [ "certainty"; "error_category"; "failure"; "runtime_id" ] ->
    (match
       ( List.assoc "runtime_id" fields
       , List.assoc "certainty" fields
       , List.assoc "error_category" fields
       , List.assoc "failure" fields )
     with
     | `String runtime_id, `String certainty, `String error_category, `String failure
       when String.trim runtime_id <> "" && String.trim error_category <> "" ->
       (match certainty_of_label certainty, failure_of_label failure with
        | Some certainty, Some failure -> Ok { runtime_id; certainty; error_category; failure }
        | None, (Some _ | None) | Some _, None ->
          Error "walk result candidate has an unknown certainty or failure")
     | _, _, _, _ -> malformed)
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> malformed

type observed =
  | Cancellation
  | Typed of candidate list * Yojson.Safe.t

let observed_of_json json =
  let untyped =
    Error "attempt holds an unknown-outcome observation without the walk's per-candidate failures"
  in
  if Yojson.Safe.equal json cancelled
  then Ok Cancellation
  else (
    match json with
    | `Assoc fields ->
      (match
         ( List.sort String.compare (List.map fst fields)
         , List.assoc_opt "schema" fields
         , List.assoc_opt "candidate_failures" fields
         , List.assoc_opt "result" fields )
       with
       | ( [ "candidate_failures"; "result"; "schema" ]
         , Some (`String found)
         , Some (`List candidates)
         , Some result )
         when String.equal found schema ->
         List.fold_left
           (fun decoded candidate ->
              Result.bind decoded (fun decoded ->
                Result.map (fun candidate -> candidate :: decoded) (candidate_of_json candidate)))
           (Ok [])
           candidates
         |> Result.map (fun candidates -> Typed (List.rev candidates, result))
       | _, _, _, _ -> untyped)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> untyped)

let read progress =
  let module P = Lane_addon_request_progress in
  List.fold_left
    (fun reading event ->
       Result.bind reading (fun reading ->
         match event with
         | P.Execution_observed (P.Outcome_unknown json) ->
           Result.bind (observed_of_json json) (fun observed ->
             match observed, reading with
             | Cancellation, (No_walk_result | Walk_result _) -> Ok reading
             | Typed (candidates, result), No_walk_result -> Ok (Walk_result { candidates; result })
             | Typed _, Walk_result _ -> Error "attempt holds more than one walk result")
         | P.Execution_observed (P.Waiting _ | P.Absent _)
         | P.Dispatch_intended | P.Admission_declined _ | P.Judgment_retained _
         | P.Preparation_intended _ | P.Preparation_observed _ | P.Replacement_intended _
         | P.Replacement_observed _ | P.Commit_intended _ | P.Commit_uncertain _
         | P.Commit_retry_observed _ | P.Commit_observed _ | P.Commit_conflicted _
         | P.Refused _ | P.Refusal_settled _ | P.Successor_intended _ | P.Successor_observed _
         | P.Observer _ -> Ok reading))
    (Ok No_walk_result)
    (P.events progress)
