module Exact = Exact_lane_run_registry
module Proposal = Keeper_plan_proposal
module Request = Keeper_plan_proposal_execution_request

type contradiction =
  | Wrong_lane of Exact.lane
  | Run_not_completed
  | Run_cancelled
  | Run_failed of
      { code : string
      ; detail : string
      }
  | Output_not_object
  | Output_missing_proposal_id
  | Output_invalid_proposal_id of Yojson.Safe.t
  | Output_proposal_id_mismatch of
      { observed : Proposal.Proposal_id.t
      ; expected : Proposal.Proposal_id.t
      }

type verification =
  | Retained_match
  | Retained_unconfirmed
  | Not_retained
  | Retained_contradiction of contradiction

let proposal_id_of_output = function
  | `Assoc fields ->
    (match List.filter_map (fun (name, value) -> if String.equal name "proposal_id" then Some value else None) fields with
     | [] -> Error Output_missing_proposal_id
     | [ (`String value as json) ] ->
       Proposal.Proposal_id.of_string value
       |> Result.map_error (fun Proposal.Proposal_id.Not_lowercase_sha256 ->
         Output_invalid_proposal_id json)
     | [ json ] -> Error (Output_invalid_proposal_id json)
     | values -> Error (Output_invalid_proposal_id (`List values)))
  | _ -> Error Output_not_object
;;

let verify ~registry ~assembler_run_id ~proposal_id =
  let verify_succeeded_output ~matched output =
    match proposal_id_of_output output with
    | Error contradiction -> Retained_contradiction contradiction
    | Ok observed when Proposal.Proposal_id.equal observed proposal_id -> matched
    | Ok observed ->
      Retained_contradiction
        (Output_proposal_id_mismatch { observed; expected = proposal_id })
  in
  match
    Exact.get
      registry
      ~run_id:(Request.Assembler_run_id.to_string assembler_run_id)
  with
  | None -> Not_retained
  | Some { Exact.lane; _ } when lane <> Exact.Assembler ->
    Retained_contradiction (Wrong_lane lane)
  | Some { status = Exact.Running; _ } ->
    Retained_contradiction Run_not_completed
  | Some
      { status =
          Exact.Completion_persistence_failed
            { intended_outcome = Exact.Succeeded; output; _ }
      ; _
      } ->
    verify_succeeded_output ~matched:Retained_unconfirmed output
  | Some
      { status =
          Exact.Completion_persistence_failed
            { intended_outcome = Exact.Cancelled; _ }
      ; _
      } ->
    Retained_contradiction Run_cancelled
  | Some
      { status =
          Exact.Completion_persistence_failed
            { intended_outcome = Exact.Failed { code; detail }; _ }
      ; _
      } ->
    Retained_contradiction (Run_failed { code; detail })
  | Some { status = Exact.Completed { outcome = Exact.Cancelled; _ }; _ } ->
    Retained_contradiction Run_cancelled
  | Some
      { status = Exact.Completed { outcome = Exact.Failed { code; detail }; _ }
      ; _
      } ->
    Retained_contradiction (Run_failed { code; detail })
  | Some
      { status = Exact.Completed { outcome = Exact.Succeeded; output; _ }
      ; _
      } ->
    verify_succeeded_output ~matched:Retained_match output
;;

let status_to_string = function
  | Retained_match -> "retained_match"
  | Retained_unconfirmed -> "retained_unconfirmed"
  | Not_retained -> "not_retained"
  | Retained_contradiction _ -> "retained_contradiction"
;;

let contradiction_to_yojson = function
  | Wrong_lane lane ->
    `Assoc
      [ "kind", `String "wrong_lane"
      ; "observed_lane", `String (Exact.lane_key lane)
      ]
  | Run_not_completed -> `Assoc [ "kind", `String "run_not_completed" ]
  | Run_cancelled -> `Assoc [ "kind", `String "run_cancelled" ]
  | Run_failed { code; detail } ->
    `Assoc
      [ "kind", `String "run_failed"
      ; "code", `String code
      ; "detail", `String detail
      ]
  | Output_not_object -> `Assoc [ "kind", `String "output_not_object" ]
  | Output_missing_proposal_id ->
    `Assoc [ "kind", `String "output_missing_proposal_id" ]
  | Output_invalid_proposal_id value ->
    `Assoc
      [ "kind", `String "output_invalid_proposal_id"
      ; "value", value
      ]
  | Output_proposal_id_mismatch { observed; expected } ->
    `Assoc
      [ "kind", `String "output_proposal_id_mismatch"
      ; "observed", `String (Proposal.Proposal_id.to_string observed)
      ; "expected", `String (Proposal.Proposal_id.to_string expected)
      ]
;;

let to_yojson verification =
  let status = "status", `String (status_to_string verification) in
  match verification with
  | Retained_match | Retained_unconfirmed | Not_retained -> `Assoc [ status ]
  | Retained_contradiction contradiction ->
    `Assoc [ status; "contradiction", contradiction_to_yojson contradiction ]
;;

let identity_fields ~assembler_run_id ~proposal_id verification =
  [ ( "assembler_run_id"
    , `String (Request.Assembler_run_id.to_string assembler_run_id) )
  ; "proposal_id", `String (Proposal.Proposal_id.to_string proposal_id)
  ; "proposal_provenance_status", `String (status_to_string verification)
  ]
;;

let attach_identity identity = function
  | `Assoc fields ->
    let non_identity_fields =
      List.filter
        (fun (name, _) -> not (List.mem_assoc name identity))
        fields
    in
    `Assoc (non_identity_fields @ identity)
  | `Null -> `Assoc identity
  | value -> `Assoc (("result", value) :: identity)
;;

let attach_to_result
      ~assembler_run_id
      ~proposal_id
      verification
      (result : Tool_result.result)
  =
  let identity = identity_fields ~assembler_run_id ~proposal_id verification in
  let attach = attach_identity identity in
  match result with
  | Tool_result.Completed payload ->
    Tool_result.Completed { payload with data = attach payload.data }
  | Tool_result.Deferred payload ->
    let data = attach payload.data in
    let metadata =
      Some (Option.fold ~none:data ~some:attach payload.metadata)
    in
    Tool_result.Deferred { payload with data; metadata }
  | Tool_result.Failed payload ->
    let data =
      match payload.data with
      | `Null ->
        `Assoc (("failure_message", `String payload.message) :: identity)
      | value -> attach value
    in
    let metadata =
      Some (Option.fold ~none:data ~some:attach payload.metadata)
    in
    Tool_result.Failed
      { payload with
        data
      ; metadata
      ; message = Yojson.Safe.to_string data
      }
;;
