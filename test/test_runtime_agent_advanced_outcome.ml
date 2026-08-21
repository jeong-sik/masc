(* Pure-decision tests for [Runtime_agent.classify_advanced_outcome].

   Live defect (2026-08-14, alpha discord-msg-1537658864005021797): a
   terminal-contract tool delivered its effect, Agent Core ended the run with
   [Terminal_tool_completed], and the runtime mapped that success to
   [Internal "runtime_agent_terminal_tool_completion_unsupported"] — an error
   surfaced to the reader after the reply had already reached the surface. *)

open Alcotest

let response ?(id = "resp-advanced") () : Agent_core.Types.api_response =
  { id
  ; model = "model-advanced"
  ; content = []
  ; usage = None
  ; stop_reason = Agent_core.Types.EndTurn
  ; telemetry = None
  }

let checkpoint () =
  Masc.Keeper_context_core.create ~eio:false ~system_prompt:"system"
  |> Masc.Keeper_context_core.resume_checkpoint_of_context

let terminal_receipt response : Agent_core.Terminal_tool_receipt.t =
  { invocation =
      Agent_core.Tool_contract.Invocation.create
        ~tool_use_id:"tool-use-terminal"
        ~turn:1
        ~schedule:
          { Agent_core.Tool_contract.planned_index = 0
          ; batch_index = 0
          ; batch_size = 1
          ; execution_mode = Agent_core.Tool_contract.Serial
          }
        ~completion:
          (Agent_core.Tool_contract.Terminal_after_success
             Agent_core.Tool_contract.Proven_post_effect)
  ; response
  ; checkpoint_stage = Agent_core.Agent.After_tool_results_appended
  }

let yielded () : Agent_core.Agent.Advanced.yielded =
  { turn = 2
  ; checkpoint_stage = Agent_core.Agent.After_tool_results_appended
  ; checkpoint = checkpoint ()
  }

let classify = Runtime_agent.classify_advanced_outcome

let test_terminal_tool_completion_is_a_completion () =
  let reply = response ~id:"resp-terminal-post" () in
  let outcome =
    Agent_core.Agent.Advanced.Terminal_tool_completed
      { turn = 3; receipt = terminal_receipt reply; checkpoint = checkpoint () }
  in
  match classify ~yield_reason:None ~boundary_response:None outcome with
  | Ok (Runtime_agent.Advanced_completed completed) ->
    check string "the receipt's provider response is the completion payload"
      "resp-terminal-post" completed.Agent_core.Types.id
  | Ok (Runtime_agent.Advanced_yielded _) ->
    fail "terminal tool completion must not classify as a cooperative yield"
  | Error error ->
    fail
      (Printf.sprintf "terminal tool completion classified as an error: %s"
         (Agent_core.Error.to_string error))

let test_completed_passes_through () =
  let reply = response ~id:"resp-plain" () in
  match
    classify ~yield_reason:None ~boundary_response:None
      (Agent_core.Agent.Advanced.Completed reply)
  with
  | Ok (Runtime_agent.Advanced_completed completed) ->
    check string "completed response passes through" "resp-plain"
      completed.Agent_core.Types.id
  | Ok (Runtime_agent.Advanced_yielded _) | Error _ ->
    fail "a plain completion must classify as completed"

let test_yield_without_decision_fails_closed () =
  match
    classify ~yield_reason:None
      ~boundary_response:(Some (response ()))
      (Agent_core.Agent.Advanced.Yielded (yielded ()))
  with
  | Error _ -> ()
  | Ok _ -> fail "a cooperative yield without a typed decision must be an error"

let test_yield_without_response_fails_closed () =
  match
    classify
      ~yield_reason:(Some Runtime_agent.Operation_queued)
      ~boundary_response:None
      (Agent_core.Agent.Advanced.Yielded (yielded ()))
  with
  | Error _ -> ()
  | Ok _ ->
    fail "a cooperative yield without its provider response must be an error"

let test_yield_with_decision_and_response_passes_through () =
  let boundary = response ~id:"resp-boundary" () in
  match
    classify
      ~yield_reason:(Some Runtime_agent.Operation_queued)
      ~boundary_response:(Some boundary)
      (Agent_core.Agent.Advanced.Yielded (yielded ()))
  with
  | Ok
      (Runtime_agent.Advanced_yielded
         (Runtime_agent.Operation_queued, carried, boundary_response)) ->
    check int "the yielded turn is carried" 2 carried.turn;
    check string "the boundary response is carried" "resp-boundary"
      boundary_response.Agent_core.Types.id
  | Ok _ | Error _ ->
    fail "a fully-typed cooperative yield must pass through unchanged"

let () =
  run
    "runtime agent advanced outcome"
    [ ( "classify"
      , [ test_case
            "terminal tool completion completes"
            `Quick
            test_terminal_tool_completion_is_a_completion
        ; test_case "completed passes through" `Quick test_completed_passes_through
        ; test_case
            "yield without decision fails closed"
            `Quick
            test_yield_without_decision_fails_closed
        ; test_case
            "yield without response fails closed"
            `Quick
            test_yield_without_response_fails_closed
        ; test_case
            "typed yield passes through"
            `Quick
            test_yield_with_decision_and_response_passes_through
        ] )
    ]
