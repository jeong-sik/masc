module Request = Keeper_assembler_request
module Flow = Keeper_assembler_exact_flow
module Proposal = Keeper_plan_proposal
module Store = Keeper_plan_proposal_store

let failure ~class_ ~effect_disposition ~message data =
  Keeper_tool_execution.failure_data
    ~class_
    ~effect_disposition
    ~message
    data
;;

let request_failure error =
  let data =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "assembler_request_rejected"
      ; "detail", Request.error_to_yojson error
      ]
  in
  failure
    ~class_:Tool_result.Policy_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message:(Yojson.Safe.to_string data)
    data
;;

let setup_failure error =
  let data =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "assembler_setup_failed"
      ; "detail", Flow.setup_error_to_yojson error
      ]
  in
  failure
    ~class_:Tool_result.Runtime_failure
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message:(Yojson.Safe.to_string data)
    data
;;

let execution_failure error =
  let data =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "assembler_execution_failed"
      ; "detail", Flow.execution_error_to_yojson error
      ]
  in
  failure
    ~class_:Tool_result.Runtime_failure
    ~effect_disposition:Tool_result.Effect_outcome_unknown
    ~message:(Yojson.Safe.to_string data)
    data
;;

let store_result_to_string = function
  | Store.Stored -> "stored"
  | Store.Already_present -> "already_present"
;;

let success_data (success : Flow.success) =
  let proposal = success.proposal in
  let proposal_id =
    Proposal.id proposal |> Proposal.Proposal_id.to_string
  in
  let approval_tools =
    Proposal.plan proposal
    |> Keeper_tool_plan.nodes
    |> List.map (fun (node : Keeper_tool_plan.node) -> `String node.tool_name)
  in
  `Assoc
    [ "ok", `Bool true
    ; "proposal_id", `String proposal_id
    ; "proposal_digest", `String (Proposal.digest proposal)
    ; "run_id", `String success.run_id
    ; "selected_slot", `String success.selected_slot
    ; "store_result", `String (store_result_to_string success.store_result)
    ; ( "execution_request"
      , `Assoc
          [ "assembler_run_id", `String success.run_id
          ; "proposal_id", `String proposal_id
          ; "approval_tools", `List approval_tools
          ] )
    ]
;;

let missing_net () =
  let data =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "assembler_runtime_resource_unavailable"
      ; "resource", `String "eio_net"
      ]
  in
  failure
    ~class_:Tool_result.Runtime_failure
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message:(Yojson.Safe.to_string data)
    data
;;

let handle ~capability_surface ~config ~keeper_name ?clock ?net ~args () =
  match Request.of_yojson ~capability_surface args with
  | Error error -> request_failure error
  | Ok request ->
    (match net with
     | None -> missing_net ()
     | Some net ->
       (match Flow.prepare ~config ~keeper_name request with
        | Error error -> setup_failure error
        | Ok prepared ->
          (match Flow.execute ~net ?clock prepared with
           | Error error -> execution_failure error
           | Ok success ->
             Keeper_tool_execution.success_data (success_data success))))
;;

let handle_without_frozen_surface () =
  let data =
    `Assoc
      [ "ok", `Bool false
      ; "error", `String "frozen_surface_required"
      ; "tool", `String "keeper_assemble_plan"
      ]
  in
  failure
    ~class_:Tool_result.Policy_rejection
    ~effect_disposition:Tool_result.Proven_pre_effect
    ~message:(Yojson.Safe.to_string data)
    data
;;
