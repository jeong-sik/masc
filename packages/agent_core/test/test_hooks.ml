(** Tests for hooks.ml — lifecycle events and hook decisions *)

open Alcotest
open Agent_sdk

let default_schedule
      ?(planned_index = 0)
      ?(batch_index = 0)
      ?(batch_size = 1)
      ?(execution_mode = Tool_contract.Serial)
      ()
  =
  let schedule : Tool_contract.schedule =
    { planned_index; batch_index; batch_size; execution_mode }
  in
  schedule
;;

let invocation ?(tool_use_id = "tu-test") ?(turn = 0) ?(planned_index = 0) () =
  Tool_contract.Invocation.create
    ~tool_use_id
    ~turn
    ~schedule:(default_schedule ~planned_index ())
    ~completion:Tool_contract.Continue_after_success
;;

let test_empty_hooks () =
  let hooks = Hooks.empty in
  check bool "before_turn is None" true (hooks.before_turn = None);
  check bool "after_turn is None" true (hooks.after_turn = None);
  check bool "pre_tool_use is None" true (hooks.pre_tool_use = None);
  check bool "post_tool_use is None" true (hooks.post_tool_use = None);
  check bool "post_tool_use_failure is None" true (hooks.post_tool_use_failure = None);
  check bool "on_stop is None" true (hooks.on_stop = None)
;;

let test_invoke_none () =
  let result =
    Hooks.invoke_validated None (Hooks.BeforeTurn { turn = 0; messages = [] })
  in
  check bool "invoke None returns Continue" true (result = Hooks.Continue)
;;

let test_invoke_continue () =
  let hook _event = Hooks.Continue in
  let result =
    Hooks.invoke_validated (Some hook) (Hooks.BeforeTurn { turn = 0; messages = [] })
  in
  check bool "hook returns Continue" true (result = Hooks.Continue)
;;

let test_hook_receives_event () =
  let received = ref "" in
  let hook = function
    | Hooks.PreToolUse { tool_name; _ } ->
      received := tool_name;
      Hooks.Continue
    | _ -> Hooks.Continue
  in
  let _result =
    Hooks.invoke_validated
      (Some hook)
      (Hooks.PreToolUse
         { invocation = invocation ()
         ; tool_name = "test_tool"
         ; input = `Null
         ; accumulated_cost_usd = 0.0
         })
  in
  check string "hook received tool_name" "test_tool" !received
;;

let test_post_tool_use_event () =
  let received_output = ref "" in
  let hook = function
    | Hooks.PostToolUse { output = Ok { content; _meta = _ }; _ } ->
      received_output := content;
      Hooks.Continue
    | _ -> Hooks.Continue
  in
  let _result =
    Hooks.invoke_validated
      (Some hook)
      (Hooks.PostToolUse
         { invocation = invocation ~tool_use_id:"tu-echo" ()
         ; tool_name = "echo"
         ; input = `Null
         ; output = Ok { Types.content = "hello"; _meta = None }
         ; result_bytes = 5
         ; duration_ms = 1.0
         })
  in
  check string "hook received output" "hello" !received_output
;;

let test_post_tool_use_failure_event () =
  let received_error = ref "" in
  let hook = function
    | Hooks.PostToolUseFailure { error; _ } ->
      received_error := error;
      Hooks.Continue
    | _ -> Hooks.Continue
  in
  let _result =
    Hooks.invoke_validated
      (Some hook)
      (Hooks.PostToolUseFailure
         { invocation = invocation ~tool_use_id:"tu-echo" ()
         ; tool_name = "echo"
         ; input = `Null
         ; error = "boom"
         })
  in
  check string "hook received error" "boom" !received_error
;;

let test_invoke_block () =
  let hook _event = Hooks.Block "blocked" in
  let result =
    Hooks.invoke_validated
      (Some hook)
      (Hooks.PreToolUse
         { invocation = invocation ~tool_use_id:"tu-danger" ()
         ; tool_name = "dangerous"
         ; input = `Null
         ; accumulated_cost_usd = 0.0
         })
  in
  check bool "hook returns Block" true (result = Hooks.Block "blocked")
;;

(* ── Decision matrix tests ────────────────────────────────── *)

let dummy_pre_tool_use =
  Hooks.PreToolUse
    { invocation = invocation ~tool_use_id:"tu-1" ~turn:1 ()
    ; tool_name = "t"
    ; input = `Null
    ; accumulated_cost_usd = 0.0
    }
;;

let dummy_before_turn = Hooks.BeforeTurn { turn = 1; messages = [] }

let dummy_before_turn_params =
  Hooks.BeforeTurnParams
    { turn = 1
    ; messages = []
    ; last_tool_results = []
    ; current_params = Hooks.default_turn_params
    ; reasoning = Hooks.empty_reasoning_summary
    }
;;

let dummy_after_turn =
  Hooks.AfterTurn
    { turn = 1
    ; response =
        { Types.id = "r"
        ; model = "m"
        ; stop_reason = EndTurn
        ; content = []
        ; usage = None
        ; telemetry = None
        }
    }
;;

let dummy_post_tool_use =
  Hooks.PostToolUse
    { invocation = invocation ~tool_use_id:"tu-1" ~turn:1 ()
    ; tool_name = "t"
    ; input = `Null
    ; output = Ok { Types.content = "ok"; _meta = None }
    ; result_bytes = 2
    ; duration_ms = 1.0
    }
;;

let dummy_post_tool_use_failure =
  Hooks.PostToolUseFailure
    { invocation = invocation ~tool_use_id:"tu-1" ~turn:1 ()
    ; tool_name = "t"
    ; input = `Null
    ; error = "err"
    }
;;

let dummy_on_stop =
  Hooks.OnStop
    { reason = EndTurn
    ; response =
        { Types.id = "r"
        ; model = "m"
        ; stop_reason = EndTurn
        ; content = []
        ; usage = None
        ; telemetry = None
        }
    }
;;

let dummy_on_error = Hooks.OnError { invocation = None; detail = "d"; context = "c" }

let dummy_on_tool_error =
  Hooks.OnToolError { invocation = invocation (); tool_name = "t"; error = "e" }
;;

(** Test that each (stage, decision) pair in the matrix is accepted. *)
let test_validate_legal_before_turn () =
  let ok = Hooks.validate_decision ~stage:Hooks.Before_turn Hooks.Continue in
  check bool "Continue at before_turn" true (Result.is_ok ok);
  let ok2 =
    Hooks.validate_decision
      ~stage:Hooks.Before_turn
      (Hooks.ElicitInput { question = "q"; schema = None; timeout_s = None })
  in
  check bool "ElicitInput at before_turn" true (Result.is_ok ok2)
;;

let test_validate_legal_before_turn_params () =
  let ok = Hooks.validate_decision ~stage:Hooks.Before_turn_params Hooks.Continue in
  check bool "Continue at before_turn_params" true (Result.is_ok ok);
  let ok2 =
    Hooks.validate_decision
      ~stage:Hooks.Before_turn_params
      (Hooks.AdjustParams Hooks.default_turn_params)
  in
  check bool "AdjustParams at before_turn_params" true (Result.is_ok ok2)
;;

let input_request =
  { Hooks.question = "authorize this command?"; schema = None; timeout_s = None }
;;

let tool_approval_prompt = { Hooks.question = "authorize this command?" }

let test_validate_legal_pre_tool_use () =
  (* RFC-OAS-039: only the typed approval decision is legal after the model
     chose the exact tool occurrence. Generic user input is never authority. *)
  let decisions =
    [ Hooks.Continue
    ; Hooks.Block "blocked"
    ; Hooks.ElicitToolApproval tool_approval_prompt
    ]
  in
  List.iter
    (fun d ->
       let ok = Hooks.validate_decision ~stage:Hooks.Pre_tool_use d in
       check
         bool
         (Printf.sprintf
            "%s at pre_tool_use"
            (Hooks.decision_kind_to_string (Hooks.classify_decision d)))
         true
         (Result.is_ok ok))
    decisions
;;

let test_validate_illegal_pre_tool_use_stays_closed () =
  let decisions =
    [ Hooks.AdjustParams Hooks.default_turn_params
    ; Hooks.ElicitInput input_request
    ; Hooks.Nudge "hint"
    ]
  in
  List.iter
    (fun d ->
       let result = Hooks.validate_decision ~stage:Hooks.Pre_tool_use d in
       check
         bool
         (Printf.sprintf
            "%s rejected at pre_tool_use"
            (Hooks.decision_kind_to_string (Hooks.classify_decision d)))
         true
         (Result.is_error result))
    decisions
;;

let test_elicit_input_illegal_where_it_cannot_settle_input () =
  (* Generic input is legal only before a turn. *)
  let stages =
    [ Hooks.Before_turn_params
    ; Hooks.After_turn
    ; Hooks.Pre_tool_use
    ; Hooks.Post_tool_use
    ; Hooks.Post_tool_use_failure
    ; Hooks.On_stop
    ; Hooks.On_error
    ; Hooks.On_tool_error
    ]
  in
  List.iter
    (fun stage ->
       let result = Hooks.validate_decision ~stage (Hooks.ElicitInput input_request) in
       check
         bool
         (Printf.sprintf "ElicitInput rejected at %s" (Hooks.hook_stage_to_string stage))
         true
         (Result.is_error result))
    stages
;;

let test_elicit_tool_approval_illegal_outside_pre_tool_use () =
  let stages =
    [ Hooks.Before_turn
    ; Hooks.Before_turn_params
    ; Hooks.After_turn
    ; Hooks.Post_tool_use
    ; Hooks.Post_tool_use_failure
    ; Hooks.On_stop
    ; Hooks.On_error
    ; Hooks.On_tool_error
    ]
  in
  List.iter
    (fun stage ->
       let result =
         Hooks.validate_decision ~stage (Hooks.ElicitToolApproval tool_approval_prompt)
       in
       check
         bool
         (Printf.sprintf
            "ElicitToolApproval rejected at %s"
            (Hooks.hook_stage_to_string stage))
         true
         (Result.is_error result))
    stages
;;

let test_validate_legal_observe_only_stages () =
  let stages =
    [ Hooks.After_turn
    ; Hooks.Post_tool_use
    ; Hooks.Post_tool_use_failure
    ; Hooks.On_stop
    ; Hooks.On_error
    ; Hooks.On_tool_error
    ]
  in
  List.iter
    (fun stage ->
       let ok = Hooks.validate_decision ~stage Hooks.Continue in
       check
         bool
         (Printf.sprintf "Continue at %s" (Hooks.hook_stage_to_string stage))
         true
         (Result.is_ok ok))
    stages
;;

(** Test that invalid decisions are rejected (fail-closed). *)
let test_validate_illegal_adjust_at_pre_tool_use () =
  let err =
    Hooks.validate_decision
      ~stage:Hooks.Pre_tool_use
      (Hooks.AdjustParams Hooks.default_turn_params)
  in
  check bool "AdjustParams at pre_tool_use is Error" true (Result.is_error err)
;;

let test_validate_illegal_block_at_on_stop () =
  let err = Hooks.validate_decision ~stage:Hooks.On_stop (Hooks.Block "blocked") in
  check bool "Block at on_stop is Error" true (Result.is_error err)
;;

(* [test_validate_illegal_elicit_at_pre_tool_use] was deleted by RFC-OAS-039.
   It pinned exactly the closure that RFC removes. Its coverage is not lost:
   [test_elicit_input_illegal_where_it_cannot_settle_input] asserts the same
   rejection for all seven stages where [ElicitInput] is still illegal, which
   is strictly broader than the single stage this one checked. *)

(** Test stage_of_event for all event variants. *)
let test_stage_of_event () =
  let cases =
    [ dummy_before_turn, Hooks.Before_turn
    ; dummy_before_turn_params, Hooks.Before_turn_params
    ; dummy_after_turn, Hooks.After_turn
    ; dummy_pre_tool_use, Hooks.Pre_tool_use
    ; dummy_post_tool_use, Hooks.Post_tool_use
    ; dummy_post_tool_use_failure, Hooks.Post_tool_use_failure
    ; dummy_on_stop, Hooks.On_stop
    ; dummy_on_error, Hooks.On_error
    ; dummy_on_tool_error, Hooks.On_tool_error
    ]
  in
  List.iter
    (fun (event, expected) ->
       check
         string
         (Printf.sprintf "stage_of_event %s" (Hooks.hook_stage_to_string expected))
         (Hooks.hook_stage_to_string expected)
         (Hooks.stage_of_event event |> Hooks.hook_stage_to_string))
    cases
;;

(** Test classify_decision round-trips with decision_kind_to_string. *)
let test_classify_and_to_string () =
  let cases =
    [ Hooks.Continue, "Continue"
    ; Hooks.Block "blocked", "Block"
    ; Hooks.AdjustParams Hooks.default_turn_params, "AdjustParams"
    ; Hooks.ElicitInput { question = "q"; schema = None; timeout_s = None }, "ElicitInput"
    ; Hooks.ElicitToolApproval { question = "q" }, "ElicitToolApproval"
    ; Hooks.Nudge "n", "Nudge"
    ; Hooks.HookFailed { stage = Hooks.Before_turn; detail = "boom" }, "HookFailed"
    ]
  in
  List.iter
    (fun (d, expected) ->
       check
         string
         (Printf.sprintf "classify %s" expected)
         expected
         (Hooks.decision_kind_to_string (Hooks.classify_decision d)))
    cases
;;

(** Test invoke_validated with a legal decision. *)
let test_invoke_validated_legal () =
  let hook _event = Hooks.Block "blocked" in
  let result = Hooks.invoke_validated (Some hook) dummy_pre_tool_use in
  check bool "validated Block at pre_tool_use passes" true (result = Hooks.Block "blocked")
;;

let contains_substring ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

let capture_traceln f =
  Eio_main.run
  @@ fun env ->
  let buffer = Buffer.create 256 in
  let captured_traceln =
    { Eio.Debug.traceln =
        (fun ?__POS__:_ format ->
          Format.kasprintf
            (fun message ->
               Buffer.add_string buffer message;
               Buffer.add_char buffer '\n')
            format)
    }
  in
  Eio.Fiber.with_binding (Eio.Stdenv.debug env)#traceln captured_traceln (fun () ->
    let result = f () in
    result, Buffer.contents buffer)
;;

let test_invoke_validated_raising_hook_returns_hook_failed () =
  let event = Hooks.BeforeTurn { turn = 0; messages = [] } in
  let raising _ = failwith "kaboom" in
  let semantic_ok, diagnostic =
    capture_traceln (fun () ->
      match Hooks.invoke_validated (Some raising) event with
      | Hooks.HookFailed { stage = Hooks.Before_turn; detail } -> String.length detail > 0
      | _ -> false)
  in
  check bool "raising hook returns before_turn HookFailed" true semantic_ok;
  check
    string
    "raising hook warning"
    {|[warn] [hooks] user hook for before_turn raised Failure("kaboom")|}
    (String.trim diagnostic)
;;

let test_invoke_validated_raising_hook_skips_on_illegal () =
  let event = Hooks.BeforeTurn { turn = 0; messages = [] } in
  let raising _ = failwith "kaboom" in
  let illegal_called = ref false in
  let on_illegal ~stage:_ ~decision:_ ~msg:_ = illegal_called := true in
  let semantic_ok, diagnostic =
    capture_traceln (fun () ->
      let _ = Hooks.invoke_validated ~on_illegal (Some raising) event in
      not !illegal_called)
  in
  check bool "raising hook does not call on_illegal" true semantic_ok;
  check
    string
    "raising hook warning"
    {|[warn] [hooks] user hook for before_turn raised Failure("kaboom")|}
    (String.trim diagnostic)
;;

let test_invoke_validated_illegal_block_returns_hook_failed_with_warning () =
  let event = Hooks.BeforeTurn { turn = 0; messages = [] } in
  let blocking _ = Hooks.Block "forbidden" in
  let semantic_ok, diagnostic =
    capture_traceln (fun () ->
      match Hooks.invoke_validated (Some blocking) event with
      | Hooks.HookFailed { stage = Hooks.Before_turn; detail } -> String.length detail > 0
      | Hooks.HookFailed _
      | Hooks.Continue
      | Hooks.AdjustParams _
      | Hooks.ElicitInput _
      | Hooks.ElicitToolApproval _
      | Hooks.Nudge _
      | Hooks.Block _ -> false)
  in
  check bool "illegal Block returns before_turn HookFailed" true semantic_ok;
  check
    string
    "illegal Block warning"
    {|[warn] [hooks] illegal hook decision Block at stage before_turn; legal: [Continue, ElicitInput, Nudge]|}
    (String.trim diagnostic)
;;

(** Test invoke_validated returns HookFailed on illegal decision. *)
let test_invoke_validated_illegal_returns_hook_failed () =
  let hook _event = Hooks.Block "blocked" in
  let called = ref false in
  let on_illegal ~stage:_ ~decision:_ ~msg:_ = called := true in
  let result = Hooks.invoke_validated ~on_illegal (Some hook) dummy_before_turn in
  (match result with
   | Hooks.HookFailed { stage; detail } ->
     check bool "stage" true (stage = Hooks.Before_turn);
     check bool "detail names Block" true (contains_substring ~needle:"Block" detail)
   | _ -> fail "expected HookFailed");
  check bool "on_illegal was called" true !called
;;

(** Pin the fail-closed result for every decision that is illegal at
    pre_tool_use (AdjustParams / ElicitInput / Nudge): the decision returns
    HookFailed and [on_illegal] receives the stage, the
    rejected decision and a message naming the decision kind. *)
let test_invoke_validated_pre_tool_use_fail_closed_pinned () =
  let illegal =
    [ Hooks.AdjustParams Hooks.default_turn_params
    ; Hooks.ElicitInput input_request
    ; Hooks.Nudge "nudge"
    ]
  in
  List.iter
    (fun decision ->
       let kind_name = Hooks.decision_kind_to_string (Hooks.classify_decision decision) in
       let hook _event = decision in
       let seen = ref None in
       let on_illegal ~stage ~decision ~msg = seen := Some (stage, decision, msg) in
       let result =
         Hooks.invoke_validated
           ~hook_name:"test_pre_tool_use_hook"
           ~on_illegal
           (Some hook)
           dummy_pre_tool_use
       in
       check
         bool
         (Printf.sprintf "%s returns HookFailed" kind_name)
         true
         (match result with
          | Hooks.HookFailed { stage; detail } ->
            stage = Hooks.Pre_tool_use && contains_substring ~needle:kind_name detail
          | _ -> false);
       match !seen with
       | None -> fail (Printf.sprintf "on_illegal not called for %s" kind_name)
       | Some (stage, rejected, msg) ->
         check string "stage reported" "pre_tool_use" (Hooks.hook_stage_to_string stage);
         check
           bool
           "rejected decision passed through"
           true
           (Hooks.classify_decision rejected = Hooks.classify_decision decision);
         check
           bool
           (Printf.sprintf "msg names %s" kind_name)
           true
           (contains_substring ~needle:kind_name msg))
    illegal
;;

(** hook_name is optional: illegal decision still returns HookFailed without it. *)
let test_invoke_validated_fail_closed_without_hook_name () =
  let hook _event = Hooks.Nudge "n" in
  let result = Hooks.invoke_validated (Some hook) dummy_pre_tool_use in
  check
    bool
    "returns HookFailed without hook_name"
    true
    (match result with
     | Hooks.HookFailed { stage = Hooks.Pre_tool_use; detail } ->
       contains_substring ~needle:"Nudge" detail
     | _ -> false)
;;

(** Test invoke_validated with None hook. *)
let test_invoke_validated_none () =
  let result = Hooks.invoke_validated None dummy_before_turn in
  check bool "None returns Continue" true (result = Hooks.Continue)
;;

(** Test invoke_validated passes through Continue on observe-only stages. *)
let test_invoke_validated_observe_only () =
  let hook _event = Hooks.Continue in
  let result = Hooks.invoke_validated (Some hook) dummy_after_turn in
  check bool "Continue at after_turn passes" true (result = Hooks.Continue)
;;

(** Test that all stages have at least Continue as legal. *)
let test_all_stages_allow_continue () =
  let stages =
    [ Hooks.Before_turn
    ; Hooks.Before_turn_params
    ; Hooks.After_turn
    ; Hooks.Pre_tool_use
    ; Hooks.Post_tool_use
    ; Hooks.Post_tool_use_failure
    ; Hooks.On_stop
    ; Hooks.On_error
    ; Hooks.On_tool_error
    ]
  in
  List.iter
    (fun stage ->
       let legal = Hooks.legal_decisions_for_stage stage in
       check
         bool
         (Printf.sprintf "%s allows Continue" (Hooks.hook_stage_to_string stage))
         true
         (List.mem Hooks.K_Continue legal))
    stages
;;

let () =
  run
    "Hooks"
    [ "empty", [ test_case "empty hooks" `Quick test_empty_hooks ]
    ; ( "invoke"
      , [ test_case "invoke None" `Quick test_invoke_none
        ; test_case "invoke Continue" `Quick test_invoke_continue
        ; test_case "invoke Block" `Quick test_invoke_block
        ; test_case "receives event" `Quick test_hook_receives_event
        ; test_case "post_tool_use event" `Quick test_post_tool_use_event
        ; test_case "post_tool_use_failure event" `Quick test_post_tool_use_failure_event
        ] )
    ; ( "decision_matrix"
      , [ test_case "legal: before_turn" `Quick test_validate_legal_before_turn
        ; test_case
            "legal: before_turn_params"
            `Quick
            test_validate_legal_before_turn_params
        ; test_case "legal: pre_tool_use" `Quick test_validate_legal_pre_tool_use
        ; test_case
            "illegal: pre_tool_use stays closed"
            `Quick
            test_validate_illegal_pre_tool_use_stays_closed
        ; test_case
            "illegal: ElicitInput where input cannot be settled"
            `Quick
            test_elicit_input_illegal_where_it_cannot_settle_input
        ; test_case
            "illegal: ElicitToolApproval outside pre_tool_use"
            `Quick
            test_elicit_tool_approval_illegal_outside_pre_tool_use
        ; test_case
            "legal: observe-only stages"
            `Quick
            test_validate_legal_observe_only_stages
        ; test_case
            "illegal: AdjustParams at pre_tool_use"
            `Quick
            test_validate_illegal_adjust_at_pre_tool_use
        ; test_case
            "illegal: Block at on_stop"
            `Quick
            test_validate_illegal_block_at_on_stop
        ; test_case "stage_of_event" `Quick test_stage_of_event
        ; test_case "classify + to_string" `Quick test_classify_and_to_string
        ; test_case "all stages allow Continue" `Quick test_all_stages_allow_continue
        ] )
    ; ( "invoke_validated"
      , [ test_case "legal decision passes" `Quick test_invoke_validated_legal
        ; test_case
            "illegal returns HookFailed"
            `Quick
            test_invoke_validated_illegal_returns_hook_failed
        ; test_case
            "raising hook returns HookFailed"
            `Quick
            test_invoke_validated_raising_hook_returns_hook_failed
        ; test_case
            "raising hook skips on_illegal"
            `Quick
            test_invoke_validated_raising_hook_skips_on_illegal
        ; test_case
            "illegal Block logs and returns HookFailed"
            `Quick
            test_invoke_validated_illegal_block_returns_hook_failed_with_warning
        ; test_case "None returns Continue" `Quick test_invoke_validated_none
        ; test_case
            "observe-only Continue passes"
            `Quick
            test_invoke_validated_observe_only
        ; test_case
            "pre_tool_use illegal decisions return HookFailed"
            `Quick
            test_invoke_validated_pre_tool_use_fail_closed_pinned
        ; test_case
            "fail-closed without hook_name returns HookFailed"
            `Quick
            test_invoke_validated_fail_closed_without_hook_name
        ] )
    ]
;;
