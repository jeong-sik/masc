open Alcotest

let test_adaptive_thinking_disabled () =
  let result =
    Masc.Keeper_agent_run.adaptive_thinking_budget
      ~enabled:false
      ~is_retry:true
      ~last_tool_results:[]
      ~current_budget:(Some 100)
  in
  check (option int) "returns current budget when disabled" (Some 100) result
;;

let test_adaptive_thinking_error_or_retry () =
  let err_res : Agent_sdk.Types.tool_result =
    Error { Agent_sdk.Types.message = "fail"; recoverable = true; error_class = None }
  in
  let result1 =
    Masc.Keeper_agent_run.adaptive_thinking_budget
      ~enabled:true
      ~is_retry:false
      ~last_tool_results:[ err_res ]
      ~current_budget:None
  in
  check (option int) "high thinking for error" (Some 1500) result1;
  let result2 =
    Masc.Keeper_agent_run.adaptive_thinking_budget
      ~enabled:true
      ~is_retry:true
      ~last_tool_results:[]
      ~current_budget:None
  in
  check (option int) "high thinking for retry" (Some 1500) result2
;;

let test_adaptive_thinking_fallback () =
  let result =
    Masc.Keeper_agent_run.adaptive_thinking_budget
      ~enabled:true
      ~is_retry:false
      ~last_tool_results:[]
      ~current_budget:(Some 500)
  in
  check (option int) "fallback to current budget" (Some 500) result
;;

let () =
  let tests =
    [ "disabled", `Quick, test_adaptive_thinking_disabled
    ; "error_or_retry", `Quick, test_adaptive_thinking_error_or_retry
    ; "fallback", `Quick, test_adaptive_thinking_fallback
    ]
  in
  Alcotest.run "Keeper_adaptive_thinking" [ "budget_logic", tests ]
;;
