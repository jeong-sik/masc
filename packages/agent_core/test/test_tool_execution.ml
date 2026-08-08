(** Tests for tool hook execution, scheduling, and lifecycle events. *)

open Alcotest
open Agent_sdk
open Types

let descriptor_with execution_mode = Tool.ordinary_descriptor execution_mode

let result_id (result : Agent_tools.tool_execution_result) =
  Tool_contract.Invocation.tool_use_id result.invocation
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0
    then true
    else if idx + needle_len > haystack_len
    then false
    else if String.sub haystack idx needle_len = needle
    then true
    else loop (idx + 1)
  in
  loop 0
;;

(** Helper: create a simple tool that echoes its input as JSON string *)
let make_echo_tool ?descriptor name =
  Tool.create
    ?descriptor
    ~name
    ~description:"echo"
    ~parameters:
      [ { Types.name = "value"
        ; description = "Optional string value"
        ; param_type = String
        ; required = false
        }
      ; { Types.name = "x"
        ; description = "Optional integer value"
        ; param_type = Integer
        ; required = false
        }
      ]
    (fun input -> Ok { Types.content = Yojson.Safe.to_string input; _meta = None })
;;

let execute_result_with_tools_in_env
      env
      ~tools
      ~hooks
      ?elicitation
      ?tool_approval
      ?event_bus
      ?journal
      ?before_tool_execution
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      tool_uses
  =
  let net = Eio.Stdenv.net env in
  let options = { Agent.default_options with hooks; elicitation; tool_approval } in
  let agent =
    Agent.create
      ~config:(Types.default_config ~model:"test-model")
      ~net
      ~tools
      ~options
      ()
  in
  let opts = Agent.options agent in
  let event_bus =
    match event_bus with
    | Some bus -> Some bus
    | None -> opts.event_bus
  in
  Agent_tools.execute_tools
    ~context:(Agent.context agent)
    ~tools:(Tool_set.to_list (Agent.tools agent))
    ~hooks:opts.hooks
    ?tool_approval:opts.tool_approval
    ~event_bus
    ?journal
    ~tracer:opts.tracer
    ~agent_name:(Agent.state agent).config.name
    ~turn_count:(Agent.state agent).turn_count
    ~usage:(Agent.state agent).usage
    ?before_tool_execution
    ?on_tool_execution_started
    ?on_tool_execution_finished
    ?on_hook_invoked
    tool_uses
;;

let test_pre_tool_approval_callback_settles_gate () =
  Eio_main.run
  @@ fun env ->
  let prompt = { Hooks.question = "Approve exact tool call?" } in
  let hooks =
    { Hooks.empty with pre_tool_use = Some (fun _ -> Hooks.ElicitToolApproval prompt) }
  in
  let run approval =
    let executed = ref 0 in
    let observed_request = ref None in
    let event_bus = Event_bus.create () in
    let event_config =
      Event_bus.subscription_config ~capacity:4 ~overflow:Event_bus.Drop_newest
      |> Result.get_ok
    in
    let subscription = Event_bus.subscribe ~config:event_config event_bus in
    let tool =
      Tool.create ~name:"gated" ~description:"gated tool" ~parameters:[] (fun _ ->
        incr executed;
        Ok { Types.content = "executed"; _meta = None })
    in
    let result =
      execute_result_with_tools_in_env
        env
        ~tools:[ tool ]
        ~hooks
        ~tool_approval:(fun request ->
          observed_request := Some request;
          approval)
        ~event_bus
        [ ToolUse { id = "gated-1"; name = "gated"; input = `Assoc [] } ]
    in
    !executed, result, Event_bus.drain subscription, !observed_request
  in
  let approved_count, approved, approved_events, approved_request = run Hooks.Approved in
  check int "approved call executes once" 1 approved_count;
  (match approved_request with
   | Some request ->
     check
       string
       "approval sees the exact tool occurrence"
       "gated-1"
       (Tool_contract.Invocation.tool_use_id request.invocation);
     check string "approval sees the exact tool name" "gated" request.tool_name;
     check bool "approval sees the exact tool input" true (`Assoc [] = request.input)
   | None -> fail "approval callback was not invoked");
  (match approved_events with
   | { Event_bus.payload = Event_bus.ToolApprovalCompleted observed; _ } :: _ ->
     check string "approval event keeps the exact tool name" "gated" observed.tool_name;
     check
       string
       "approval event keeps the exact tool occurrence"
       "gated-1"
       (Tool_contract.Invocation.tool_use_id observed.invocation);
     check
       bool
       "approval event keeps the exact decision"
       true
       (observed.approval = Hooks.Approved)
   | _ -> fail "approved gate did not publish its typed approval result");
  (match approved with
   | Ok { Agent_tools.completed_results = [ result ]; completion = Continue_after_batch }
     ->
     check
       bool
       "approved result succeeds"
       false
       (Types.tool_result_outcome_is_error result.outcome)
   | Ok _ -> fail "approved gate returned an unexpected report"
   | Error _ -> fail "approved gate failed");
  List.iter
    (fun approval ->
       let count, rejected, events, _ = run approval in
       check int "rejected call does not execute" 0 count;
       (match events with
        | { Event_bus.payload = Event_bus.ToolApprovalCompleted observed; _ } :: _ ->
          check bool "rejected approval is preserved" true (observed.approval = approval)
        | _ -> fail "rejected gate did not publish its typed approval result");
       match rejected with
       | Ok
           { Agent_tools.completed_results =
               [ { outcome = Tool_failed { failure_kind = Non_retryable_tool_error; _ }
                 ; _
                 }
               ]
           ; completion = Continue_after_batch
           } -> ()
       | Ok _ -> fail "rejected gate did not return a typed tool failure"
       | Error _ -> fail "rejected gate failed")
    [ Hooks.Denied; Hooks.Timed_out ];
  let missing_callback_count = ref 0 in
  let missing_callback_tool =
    Tool.create ~name:"gated" ~description:"gated tool" ~parameters:[] (fun _ ->
      incr missing_callback_count;
      Ok { Types.content = "must-not-run"; _meta = None })
  in
  (match
     execute_result_with_tools_in_env
       env
       ~tools:[ missing_callback_tool ]
       ~hooks
       [ ToolUse { id = "gated-missing"; name = "gated"; input = `Assoc [] } ]
   with
   | Error
       { Agent_tools.cause =
           Agent_tools.Hook_failure
             (Agent_tools.Hook_execution_failed { stage = Hooks.Pre_tool_use; _ })
       ; _
       } -> ()
   | Error _ -> fail "missing callback returned the wrong typed failure"
   | Ok _ -> fail "missing callback did not fail closed");
  check int "missing callback opens no effect" 0 !missing_callback_count;
  let generic_input_hook =
    { Hooks.empty with
      pre_tool_use =
        Some
          (fun _ ->
            Hooks.ElicitInput
              { question = "Approve exact tool call?"
              ; schema = Some (`Assoc [ "type", `String "boolean" ])
              ; timeout_s = None
              })
    }
  in
  List.iter
    (fun (case, answer) ->
       let generic_callback_count = ref 0 in
       let generic_effect_count = ref 0 in
       let generic_input_tool =
         Tool.create ~name:"gated" ~description:"gated tool" ~parameters:[] (fun _ ->
           incr generic_effect_count;
           Ok { Types.content = "must-not-run"; _meta = None })
       in
       (match
          execute_result_with_tools_in_env
            env
            ~tools:[ generic_input_tool ]
            ~hooks:generic_input_hook
            ~elicitation:(fun _ ->
              incr generic_callback_count;
              Hooks.Answer answer)
            [ ToolUse { id = "gated-generic"; name = "gated"; input = `Assoc [] } ]
        with
        | Error
            { Agent_tools.cause =
                Agent_tools.Hook_failure
                  (Agent_tools.Hook_execution_failed { stage = Hooks.Pre_tool_use; _ })
            ; _
            } -> ()
        | Error _ -> fail "generic JSON elicitation returned the wrong typed failure"
        | Ok _ -> fail "generic JSON elicitation became a tool approval");
       check int (case ^ ": generic callback is not consulted") 0 !generic_callback_count;
       check int (case ^ ": generic reply opens no effect") 0 !generic_effect_count)
    [ "false", `Bool false
    ; "schema mismatch", `Assoc [ "approved", `Bool true ]
    ; "malformed approval-shaped string", `String "{approved:true}"
    ]
;;

let approval_failure_fixture env callback =
  let executed = ref 0 in
  let tool =
    Tool.create ~name:"gated" ~description:"gated tool" ~parameters:[] (fun _ ->
      incr executed;
      Ok { Types.content = "must-not-run"; _meta = None })
  in
  let hooks =
    { Hooks.empty with
      pre_tool_use = Some (fun _ -> Hooks.ElicitToolApproval { question = "Approve?" })
    }
  in
  let result =
    execute_result_with_tools_in_env
      env
      ~tools:[ tool ]
      ~hooks
      ~tool_approval:callback
      [ ToolUse { id = "gated-callback"; name = "gated"; input = `Assoc [] } ]
  in
  !executed, result
;;

let test_pre_tool_approval_callback_failure_is_typed () =
  Eio_main.run
  @@ fun env ->
  let executed, result =
    approval_failure_fixture env (fun _ -> failwith "approval unavailable")
  in
  check int "callback failure opens no effect" 0 executed;
  match result with
  | Error
      { Agent_tools.cause =
          Agent_tools.Hook_failure
            (Agent_tools.Hook_execution_failed { stage = Hooks.Pre_tool_use; detail; _ })
      ; _
      } ->
    check
      bool
      "callback failure detail is retained"
      true
      (contains_substring ~needle:"approval unavailable" detail)
  | Error _ -> fail "callback failure returned the wrong typed error"
  | Ok _ -> fail "callback failure did not fail closed"
;;

let test_pre_tool_approval_reserved_exception_propagates () =
  Eio_main.run
  @@ fun env ->
  match approval_failure_fixture env (fun _ -> raise Sys.Break) with
  | exception Sys.Break -> ()
  | _ -> fail "reserved callback exception was flattened"
;;

let test_pre_tool_approval_eio_cancellation_propagates () =
  Eio_main.run
  @@ fun env ->
  match approval_failure_fixture env (fun _ -> raise (Eio.Cancel.Cancelled Exit)) with
  | exception Eio.Cancel.Cancelled Exit -> ()
  | _ -> fail "caller cancellation was flattened"
;;

let execute_with_tools_in_env
      env
      ~tools
      ~hooks
      ?event_bus
      ?before_tool_execution
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      tool_uses
  =
  match
    execute_result_with_tools_in_env
      env
      ~tools
      ~hooks
      ?event_bus
      ?before_tool_execution
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      tool_uses
  with
  | Ok report -> report.Agent_tools.completed_results
  | Error
      { Agent_tools.completed_results
      ; completion = _
      ; cause = Agent_tools.Hook_failure (Agent_tools.Hook_execution_failed failure)
      } ->
    failf
      "unexpected hook failure %s at %s after %d completed result(s): %s"
      failure.hook_name
      (Hooks.hook_stage_to_string failure.stage)
      (List.length completed_results)
      failure.detail
  | Error
      { Agent_tools.cause = Agent_tools.Observer_failure { exception_; backtrace; _ }; _ }
    -> Printexc.raise_with_backtrace exception_ backtrace
  | Error { Agent_tools.cause = Agent_tools.Durability_failure { detail; _ }; _ } ->
    failf "unexpected durable execution failure: %s" detail
;;

(** Helper: create a minimal agent inside Eio with given hooks.
    Returns execute_tools results for the given tool_uses. *)
let run_execute_with_tools
      ~tools
      ~hooks
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      tool_uses
  =
  Eio_main.run
  @@ fun env ->
  execute_with_tools_in_env
    env
    ~tools
    ~hooks
    ?on_tool_execution_started
    ?on_tool_execution_finished
    ?on_hook_invoked
    tool_uses
;;

let run_execute ~hooks tool_uses =
  run_execute_with_tools
    ~tools:[ make_echo_tool "safe"; make_echo_tool "dangerous" ]
    ~hooks
    tool_uses
;;

(* --- Test cases --- *)

let test_tool_lifecycle_callback_exceptions_propagate () =
  let call ~on_tool_execution_started ~on_tool_execution_finished () =
    ignore
      (run_execute_with_tools
         ~tools:[ make_echo_tool "safe" ]
         ~hooks:Hooks.empty
         ~on_tool_execution_started
         ~on_tool_execution_finished
         [ ToolUse { id = "t1"; name = "safe"; input = `Assoc [ "x", `Int 1 ] } ])
  in
  let no_started_failure ~invocation:_ ~tool_name:_ ~input:_ = () in
  let no_finished_failure ~invocation:_ ~tool_name:_ ~content:_ ~is_error:_ = () in
  let started_failure ~invocation:_ ~tool_name:_ ~input:_ =
    failwith "started callback boom"
  in
  let finished_failure ~invocation:_ ~tool_name:_ ~content:_ ~is_error:_ =
    failwith "finished callback boom"
  in
  check_raises
    "started callback exception propagates"
    (Failure "started callback boom")
    (call
       ~on_tool_execution_started:started_failure
       ~on_tool_execution_finished:no_finished_failure);
  check_raises
    "finished callback exception propagates"
    (Failure "finished callback boom")
    (call
       ~on_tool_execution_started:no_started_failure
       ~on_tool_execution_finished:finished_failure)
;;

let test_pre_hook_observer_exception_propagates () =
  let observer ~invocation:_ ~hook_name:_ ~decision:_ ~detail:_ =
    failwith "hook observer boom"
  in
  check_raises
    "hook observer exception propagates"
    (Failure "hook observer boom")
    (fun () ->
       ignore
         (run_execute_with_tools
            ~tools:[ make_echo_tool "safe" ]
            ~hooks:Hooks.empty
            ~on_hook_invoked:observer
            [ ToolUse { id = "t1"; name = "safe"; input = `Assoc [ "x", `Int 1 ] } ]))
;;

let test_reserved_callback_exception_is_not_tagged () =
  let on_tool_execution_started ~invocation:_ ~tool_name:_ ~input:_ = raise Sys.Break in
  match
    run_execute_with_tools
      ~tools:[ make_echo_tool "safe" ]
      ~hooks:Hooks.empty
      ~on_tool_execution_started
      [ ToolUse { id = "t1"; name = "safe"; input = `Assoc [] } ]
  with
  | _ -> fail "reserved callback exception must propagate"
  | exception Sys.Break -> ()
;;

let test_post_hook_observer_exception_propagates_after_completion () =
  let executed = ref 0 in
  let started = ref 0 in
  let finished = ref 0 in
  let tool =
    Tool.create ~name:"safe" ~description:"" ~parameters:[] (fun _ ->
      incr executed;
      Ok { Types.content = "done"; _meta = None })
  in
  let observer ~invocation:_ ~hook_name ~decision:_ ~detail:_ =
    if String.equal hook_name "post_tool_use" then failwith "post observer boom"
  in
  let on_tool_execution_started ~invocation:_ ~tool_name:_ ~input:_ = incr started in
  let on_tool_execution_finished ~invocation:_ ~tool_name:_ ~content:_ ~is_error:_ =
    incr finished
  in
  check_raises
    "post observer exception propagates"
    (Failure "post observer boom")
    (fun () ->
       ignore
         (run_execute_with_tools
            ~tools:[ tool ]
            ~hooks:Hooks.empty
            ~on_tool_execution_started
            ~on_tool_execution_finished
            ~on_hook_invoked:observer
            [ ToolUse { id = "t1"; name = "safe"; input = `Assoc [] } ]));
  check int "tool executed exactly once" 1 !executed;
  check int "execution start observed" 1 !started;
  check int "execution completion observed before propagation" 1 !finished
;;

let test_post_hook_failure_is_typed_agent_error () =
  Eio_main.run
  @@ fun env ->
  let executed = ref 0 in
  let started = ref 0 in
  let finished = ref 0 in
  let tool =
    Tool.create ~name:"safe" ~description:"" ~parameters:[] (fun _ ->
      incr executed;
      Ok { Types.content = "done"; _meta = None })
  in
  let hooks =
    { Hooks.empty with post_tool_use = Some (fun _ -> failwith "post hook boom") }
  in
  let result =
    execute_result_with_tools_in_env
      env
      ~tools:[ tool ]
      ~hooks
      ~on_tool_execution_started:(fun ~invocation:_ ~tool_name:_ ~input:_ -> incr started)
      ~on_tool_execution_finished:
        (fun
          ~invocation:_ ~tool_name:_ ~content:_ ~is_error:_ -> incr finished)
      [ ToolUse { id = "t1"; name = "safe"; input = `Assoc [] } ]
  in
  (match result with
   | Error
       { Agent_tools.completed_results = [ completed ]
       ; cause =
           Agent_tools.Hook_failure
             (Agent_tools.Hook_execution_failed
                { hook_name = "post_tool_use"
                ; stage = Hooks.Post_tool_use
                ; tool_name = "safe"
                ; invocation
                ; detail
                })
       } ->
     check
       string
       "hook invocation id"
       "t1"
       (Tool_contract.Invocation.tool_use_id invocation);
     check
       bool
       "hook exception detail retained"
       true
       (contains_substring ~needle:"post hook boom" detail);
     check string "completed result retained" "done" completed.content
   | Ok _ -> fail "post hook failure was returned as successful tool results"
   | Error _ -> fail "unexpected hook execution error payload");
  check int "tool effect happened once" 1 !executed;
  check int "execution start observed" 1 !started;
  check int "execution completion observed" 1 !finished
;;

let test_error_hooks_run_after_prior_hook_failure () =
  Eio_main.run
  @@ fun env ->
  let observed = ref [] in
  let record name =
    observed := name :: !observed;
    Hooks.Continue
  in
  let tool =
    Tool.create ~name:"fails" ~description:"" ~parameters:[] (fun _ ->
      Error
        { Types.message = "tool failed"
        ; recoverable = false
        ; error_class = Some Types.Deterministic
        })
  in
  let hooks =
    { Hooks.empty with
      post_tool_use =
        Some
          (fun _ ->
            observed := "post_tool_use" :: !observed;
            failwith "first hook failed")
    ; post_tool_use_failure = Some (fun _ -> record "post_tool_use_failure")
    ; on_tool_error = Some (fun _ -> record "on_tool_error")
    }
  in
  let result =
    execute_result_with_tools_in_env
      env
      ~tools:[ tool ]
      ~hooks
      ~on_hook_invoked:(fun ~invocation:_ ~hook_name ~decision:_ ~detail:_ ->
        if String.equal hook_name "on_tool_error" then failwith "observer failed")
      [ ToolUse { id = "failure-1"; name = "fails"; input = `Assoc [] } ]
  in
  (match result with
   | Error
       { Agent_tools.completed_results = [ completed ]
       ; cause = Agent_tools.Observer_failure { invocation; exception_; _ }
       } ->
     check string "tool failure remains visible" "tool failed" completed.content;
     check
       string
       "observer failure occurrence"
       "failure-1"
       (Tool_contract.Invocation.tool_use_id invocation);
     check
       string
       "observer failure propagates"
       "Failure(\"observer failed\")"
       (Printexc.to_string exception_)
   | Ok _ -> fail "observer failure must remain terminal"
   | Error _ -> fail "later observer failure was hidden by the hook failure");
  check
    (list string)
    "later error hooks still run"
    [ "post_tool_use"; "post_tool_use_failure"; "on_tool_error" ]
    (List.rev !observed)
;;

let test_concurrent_journal_failure_retains_sibling_results () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let first_started, resolve_first = Eio.Promise.create () in
  let sibling_started, resolve_sibling = Eio.Promise.create () in
  let later_serial_runs = ref 0 in
  let finished_ids = ref [] in
  let journal =
    Durable_event.create
      ~on_append:(function
        | Durable_event.Tool_completed { tool_name = "first"; _ } ->
          failwith "journal observer boom"
        | _ -> ())
      ()
  in
  let concurrent_tool name resolve_self await_other =
    Tool.create
      ~descriptor:(descriptor_with Tool_contract.Concurrent)
      ~name
      ~description:""
      ~parameters:[]
      (fun _ ->
         Eio.Promise.resolve resolve_self ();
         Eio.Time.with_timeout_exn clock 0.05 (fun () -> Eio.Promise.await await_other);
         Eio.Time.sleep clock 0.005;
         Ok { Types.content = name; _meta = None })
  in
  let later_serial =
    Tool.create
      ~descriptor:(descriptor_with Tool_contract.Serial)
      ~name:"later_serial"
      ~description:""
      ~parameters:[]
      (fun _ ->
         incr later_serial_runs;
         Ok { Types.content = "must not run"; _meta = None })
  in
  let result =
    execute_result_with_tools_in_env
      env
      ~tools:
        [ concurrent_tool "first" resolve_first sibling_started
        ; concurrent_tool "sibling" resolve_sibling first_started
        ; later_serial
        ]
      ~hooks:Hooks.empty
      ~journal
      ~on_tool_execution_finished:(fun ~invocation ~tool_name:_ ~content:_ ~is_error:_ ->
        finished_ids := Tool_contract.Invocation.tool_use_id invocation :: !finished_ids)
      [ ToolUse { id = "t1"; name = "first"; input = `Assoc [] }
      ; ToolUse { id = "t2"; name = "sibling"; input = `Assoc [] }
      ; ToolUse { id = "t3"; name = "later_serial"; input = `Assoc [] }
      ]
  in
  (match result with
   | Error
       { Agent_tools.completed_results = [ first; sibling ]
       ; cause = Agent_tools.Observer_failure { invocation; exception_; _ }
       } ->
     check string "first result order" "t1" (result_id first);
     check string "sibling result order" "t2" (result_id sibling);
     check string "first result retained" "first" first.content;
     check string "sibling result retained" "sibling" sibling.content;
     check
       string
       "observer failure exact occurrence"
       "t1"
       (Tool_contract.Invocation.tool_use_id invocation);
     check
       string
       "original observer exception retained"
       "Failure(\"journal observer boom\")"
       (Printexc.to_string exception_)
   | Ok _ -> fail "observer failure must remain terminal"
   | Error _ -> fail "unexpected concurrent execution failure");
  check
    (list string)
    "both concurrent completion observers ran"
    [ "t1"; "t2" ]
    (List.sort String.compare !finished_ids);
  check int "later serial batch was not started" 0 !later_serial_runs;
  check
    int
    "journal retained both Tool_completed events"
    2
    (Durable_event.events journal
     |> List.filter (function
       | Durable_event.Tool_completed _ -> true
       | _ -> false)
     |> List.length)
;;

let test_block_emits_no_execution_lifecycle () =
  let executed = ref 0 in
  let started = ref 0 in
  let finished = ref 0 in
  let tool =
    Tool.create ~name:"safe" ~description:"" ~parameters:[] (fun _ ->
      incr executed;
      Ok { Types.content = "must not run"; _meta = None })
  in
  let hooks =
    { Hooks.empty with pre_tool_use = Some (fun _ -> Hooks.Block "caller denied") }
  in
  let results =
    run_execute_with_tools
      ~tools:[ tool ]
      ~hooks
      ~on_tool_execution_started:(fun ~invocation:_ ~tool_name:_ ~input:_ -> incr started)
      ~on_tool_execution_finished:
        (fun
          ~invocation:_ ~tool_name:_ ~content:_ ~is_error:_ -> incr finished)
      [ ToolUse { id = "t1"; name = "safe"; input = `Assoc [] } ]
  in
  (match results with
   | [ result ] ->
     check string "block reason" "caller denied" result.content;
     check
       bool
       "block remains model-visible error"
       true
       (tool_result_outcome_is_error result.outcome)
   | _ -> fail "expected one blocked result");
  check int "tool did not execute" 0 !executed;
  check int "execution start was not fabricated" 0 !started;
  check int "execution completion was not fabricated" 0 !finished
;;

let test_block_is_deterministic_failure () =
  let hooks =
    { Hooks.empty with pre_tool_use = Some (fun _event -> Hooks.Block "caller denied") }
  in
  let results =
    run_execute
      ~hooks
      [ ToolUse
          { id = "t1"
          ; name = "dangerous"
          ; input = `Assoc [ "value", `String "must not run" ]
          }
      ]
  in
  match results with
  | [ result ] ->
    check string "id" "t1" (result_id result);
    check string "reason is verbatim" "caller denied" result.content;
    check bool "is error" true (tool_result_outcome_is_error result.outcome);
    (match result.outcome with
     | Tool_failed
         { failure_kind = Agent_tools.Non_retryable_tool_error
         ; error_class = Some Types.Deterministic
         } -> ()
     | _ -> fail "expected deterministic non-retryable tool error")
  | _ -> fail "expected exactly one result"
;;

let test_unknown_tool_is_uniform_validation_with_full_diagnostics () =
  let names = List.init 14 (fun index -> Printf.sprintf "tool_%02d" index) in
  let run tools =
    match
      run_execute_with_tools
        ~tools
        ~hooks:Hooks.empty
        [ ToolUse { id = "missing"; name = "Missing"; input = `Assoc [] } ]
    with
    | [ result ] -> result
    | _ -> fail "expected one unknown-tool result"
  in
  let check_validation label result =
    match result.Agent_tools.outcome with
    | Tool_failed
        { failure_kind = Agent_tools.Validation_error
        ; error_class = Some Types.Deterministic
        } -> ()
    | _ -> fail (label ^ " must be a deterministic validation failure")
  in
  let without_registered_tools = run [] in
  check_validation "empty catalog" without_registered_tools;
  check
    string
    "empty catalog diagnostic"
    "Tool not found: Missing. Available tools: (none)"
    without_registered_tools.content;
  let with_registered_tools = run (List.map make_echo_tool names) in
  check_validation "populated catalog" with_registered_tools;
  check
    string
    "all available names are rendered without truncation"
    ("Tool not found: Missing. Available tools: " ^ String.concat "," names)
    with_registered_tools.content
;;

let test_non_tool_use_blocks_filtered () =
  (* Non-ToolUse blocks (Text, Thinking) must be filtered out, not produce
     bogus ("", "", false) triples. Regression test for issue #327. *)
  let hooks = Hooks.empty in
  let results =
    run_execute
      ~hooks
      [ Text "some assistant text"
      ; ToolUse { id = "t1"; name = "safe"; input = `Assoc [ "value", `String "data" ] }
      ; Thinking { signature = None; content = "reasoning" }
      ; ToolUse { id = "t2"; name = "safe"; input = `Assoc [ "value", `String "more" ] }
      ]
  in
  (* Only the 2 ToolUse blocks should produce results *)
  check int "result count" 2 (List.length results);
  let sorted =
    List.sort (fun a b -> String.compare (result_id a) (result_id b)) results
  in
  match sorted with
  | [ first; second ] ->
    check string "first id" "t1" (result_id first);
    check string "second id" "t2" (result_id second)
  | _ -> fail "expected exactly two results"
;;

let test_only_non_tool_use_blocks () =
  (* When all blocks are non-ToolUse, result should be empty *)
  let hooks = Hooks.empty in
  let results =
    run_execute
      ~hooks
      [ Text "just text"; Thinking { signature = None; content = "thoughts" } ]
  in
  check int "empty results" 0 (List.length results)
;;

let test_concurrent_tools_share_batch () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let started_a, resolve_a = Eio.Promise.create () in
  let started_b, resolve_b = Eio.Promise.create () in
  let make_barrier_tool name resolve_self await_other =
    make_echo_tool ~descriptor:(descriptor_with Tool_contract.Concurrent) name
    |> fun tool ->
    { tool with
      Tool.handler =
        (fun _execution_env input ->
          Eio.Promise.resolve resolve_self ();
          Eio.Time.with_timeout_exn clock 0.05 (fun () -> Eio.Promise.await await_other);
          Ok { Types.content = Yojson.Safe.to_string input; _meta = None })
    }
  in
  let tools =
    [ make_barrier_tool "read_a" resolve_a started_b
    ; make_barrier_tool "read_b" resolve_b started_a
    ]
  in
  let results =
    execute_with_tools_in_env
      env
      ~tools
      ~hooks:Hooks.empty
      [ ToolUse { id = "t1"; name = "read_a"; input = `Assoc [ "value", `String "a" ] }
      ; ToolUse { id = "t2"; name = "read_b"; input = `Assoc [ "value", `String "b" ] }
      ]
  in
  match results with
  | [ first; second ]
    when (not (tool_result_outcome_is_error first.outcome))
         && not (tool_result_outcome_is_error second.outcome) -> ()
  | _ -> fail "concurrent batch should allow both tools to start"
;;

let test_serial_tools_run_sequentially () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let running = ref false in
  let make_guarded_tool name =
    make_echo_tool ~descriptor:(descriptor_with Tool_contract.Serial) name
    |> fun tool ->
    { tool with
      Tool.handler =
        (fun _execution_env _ ->
          if !running then failwith "serial overlap detected";
          running := true;
          Eio.Time.sleep clock 0.01;
          running := false;
          Ok { Types.content = name; _meta = None })
    }
  in
  let results =
    execute_with_tools_in_env
      env
      ~tools:[ make_guarded_tool "write_a"; make_guarded_tool "write_b" ]
      ~hooks:Hooks.empty
      [ ToolUse { id = "t1"; name = "write_a"; input = `Assoc [] }
      ; ToolUse { id = "t2"; name = "write_b"; input = `Assoc [] }
      ]
  in
  match results with
  | [ first; second ]
    when first.content = "write_a"
         && (not (tool_result_outcome_is_error first.outcome))
         && second.content = "write_b"
         && not (tool_result_outcome_is_error second.outcome) -> ()
  | _ -> fail "serial tools should execute sequentially"
;;

let test_undeclared_tools_default_to_sequential () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let running = ref false in
  let make_guarded_tool name =
    make_echo_tool name
    |> fun tool ->
    { tool with
      Tool.handler =
        (fun _execution_env _ ->
          if !running then failwith "undeclared tool overlap detected";
          running := true;
          Eio.Time.sleep clock 0.01;
          running := false;
          Ok { Types.content = name; _meta = None })
    }
  in
  let results =
    execute_with_tools_in_env
      env
      ~tools:[ make_guarded_tool "implicit_a"; make_guarded_tool "implicit_b" ]
      ~hooks:Hooks.empty
      [ ToolUse { id = "t1"; name = "implicit_a"; input = `Assoc [] }
      ; ToolUse { id = "t2"; name = "implicit_b"; input = `Assoc [] }
      ]
  in
  match results with
  | [ first; second ]
    when first.content = "implicit_a"
         && (not (tool_result_outcome_is_error first.outcome))
         && second.content = "implicit_b"
         && not (tool_result_outcome_is_error second.outcome) -> ()
  | _ -> fail "undeclared tools should stay sequential by default"
;;

let test_serial_barrier_splits_concurrent_batches () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let concurrent_running = ref 0 in
  let serial_running = ref false in
  let make_concurrent_tool name =
    make_echo_tool ~descriptor:(descriptor_with Tool_contract.Concurrent) name
    |> fun tool ->
    { tool with
      Tool.handler =
        (fun _execution_env _ ->
          if !serial_running then failwith "concurrent call overlapped with serial call";
          incr concurrent_running;
          Eio.Time.sleep clock 0.02;
          decr concurrent_running;
          Ok { Types.content = name; _meta = None })
    }
  in
  let make_serial_tool name =
    make_echo_tool ~descriptor:(descriptor_with Tool_contract.Serial) name
    |> fun tool ->
    { tool with
      Tool.handler =
        (fun _execution_env _ ->
          if !concurrent_running > 0
          then failwith "serial call overlapped with concurrent call";
          serial_running := true;
          Eio.Time.sleep clock 0.02;
          serial_running := false;
          Ok { Types.content = name; _meta = None })
    }
  in
  let tools =
    [ make_concurrent_tool "concurrent_before"
    ; make_serial_tool "serial_mid"
    ; make_concurrent_tool "concurrent_after"
    ]
  in
  let results =
    execute_with_tools_in_env
      env
      ~tools
      ~hooks:Hooks.empty
      [ ToolUse { id = "t1"; name = "concurrent_before"; input = `Assoc [] }
      ; ToolUse { id = "t2"; name = "serial_mid"; input = `Assoc [] }
      ; ToolUse { id = "t3"; name = "concurrent_after"; input = `Assoc [] }
      ]
  in
  match results with
  | [ first; second; third ]
    when first.content = "concurrent_before"
         && (not (tool_result_outcome_is_error first.outcome))
         && second.content = "serial_mid"
         && (not (tool_result_outcome_is_error second.outcome))
         && third.content = "concurrent_after"
         && not (tool_result_outcome_is_error third.outcome) -> ()
  | _ -> fail "serial tool should separate concurrent batches"
;;

let test_dispatch_passes_exact_tool_invocation () =
  let tool =
    Tool.of_schema
      ~descriptor:(descriptor_with Tool_contract.Concurrent)
      (Types.tool_schema_of_params
         ~name:"observe_invocation"
         ~description:"Return exact invocation identity"
         ~parameters:[]
         ())
      (fun execution_env _ ->
         match Tool.Execution_env.invocation execution_env with
         | Some invocation ->
           Eio.Fiber.yield ();
           Ok
             { Types.content =
                 Printf.sprintf
                   "%s:%d:%d"
                   (Tool_contract.Invocation.tool_use_id invocation)
                   (Tool_contract.Invocation.turn invocation)
                   (Tool_contract.Invocation.planned_index invocation)
             ; _meta = None
             }
         | None ->
           Error
             { Types.message = "missing exact invocation"
             ; recoverable = false
             ; error_class = Some Types.Deterministic
             })
  in
  match
    run_execute_with_tools
      ~tools:[ tool ]
      ~hooks:Hooks.empty
      [ ToolUse
          { id = "provider-call-duplicate"
          ; name = "observe_invocation"
          ; input = `Assoc []
          }
      ; ToolUse
          { id = "provider-call-duplicate"
          ; name = "observe_invocation"
          ; input = `Assoc []
          }
      ]
  with
  | [ first; second ] ->
    check string "first exact occurrence" "provider-call-duplicate:0:0" first.content;
    check string "second exact occurrence" "provider-call-duplicate:0:1" second.content;
    check bool "first tool succeeded" false (tool_result_outcome_is_error first.outcome);
    check bool "second tool succeeded" false (tool_result_outcome_is_error second.outcome)
  | _ -> fail "expected two invocation-aware results"
;;

let invocation_key invocation =
  let schedule = Tool_contract.Invocation.schedule invocation in
  let execution_mode =
    match schedule.execution_mode with
    | Tool_contract.Concurrent -> "concurrent"
    | Tool_contract.Serial -> "serial"
  in
  Printf.sprintf
    "%S:%d:%d:%d:%d:%s"
    (Tool_contract.Invocation.tool_use_id invocation)
    (Tool_contract.Invocation.turn invocation)
    schedule.planned_index
    schedule.batch_index
    schedule.batch_size
    execution_mode
;;

let test_lifecycle_surfaces_share_exact_tool_invocation () =
  Eio_main.run
  @@ fun env ->
  let pre_invocations = ref [] in
  let post_invocations = ref [] in
  let failure_invocations = ref [] in
  let handler_invocations = ref [] in
  let started_invocations = ref [] in
  let finished_invocations = ref [] in
  let capture target invocation = target := invocation_key invocation :: !target in
  let hooks =
    { Hooks.empty with
      pre_tool_use =
        Some
          (function
            | Hooks.PreToolUse { invocation; _ } ->
              capture pre_invocations invocation;
              Hooks.Continue
            | _ -> fail "expected PreToolUse")
    ; post_tool_use =
        Some
          (function
            | Hooks.PostToolUse { invocation; _ } ->
              capture post_invocations invocation;
              Hooks.Continue
            | _ -> fail "expected PostToolUse")
    ; post_tool_use_failure =
        Some
          (function
            | Hooks.PostToolUseFailure { invocation; _ } ->
              capture failure_invocations invocation;
              Hooks.Continue
            | _ -> fail "expected PostToolUseFailure")
    }
  in
  let event_bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:6 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let subscription = Event_bus.subscribe ~config event_bus in
  let tool name result =
    Tool.of_schema
      (Types.tool_schema_of_params ~name ~description:"" ~parameters:[] ())
      (fun execution_env _ ->
         Option.iter
           (capture handler_invocations)
           (Tool.Execution_env.invocation execution_env);
         result)
  in
  let success = Ok { Types.content = "done"; _meta = None } in
  let failure =
    Error
      { Types.message = "expected failure"
      ; recoverable = false
      ; error_class = Some Types.Deterministic
      }
  in
  let results =
    execute_with_tools_in_env
      env
      ~tools:[ tool "exact_occurrence" success; tool "exact_failure" failure ]
      ~hooks
      ~event_bus
      ~on_tool_execution_started:(fun ~invocation ~tool_name:_ ~input:_ ->
        capture started_invocations invocation)
      ~on_tool_execution_finished:(fun ~invocation ~tool_name:_ ~content:_ ~is_error:_ ->
        capture finished_invocations invocation)
      [ ToolUse { id = ""; name = "exact_occurrence"; input = `Assoc [] }
      ; ToolUse { id = ""; name = "exact_occurrence"; input = `Assoc [] }
      ; ToolUse { id = ""; name = "exact_failure"; input = `Assoc [] }
      ]
  in
  check int "all blank-id calls completed" 3 (List.length results);
  let called_invocations, completed_invocations =
    List.fold_left
      (fun (called, completed) (event : Event_bus.event) ->
         match event.payload with
         | ToolCalled { invocation; _ } -> invocation_key invocation :: called, completed
         | ToolCompleted { invocation; _ } ->
           called, invocation_key invocation :: completed
         | _ -> called, completed)
      ([], [])
      (Event_bus.drain subscription)
  in
  let expected_all =
    [ "\"\":0:0:0:1:serial"; "\"\":0:1:1:1:serial"; "\"\":0:2:2:1:serial" ]
  in
  let expected_failure = [ "\"\":0:2:2:1:serial" ] in
  let result_invocations =
    List.map
      (fun (result : Agent_tools.tool_execution_result) ->
         invocation_key result.invocation)
      results
  in
  let check_occurrences label expected actual =
    check (list string) label expected (List.rev actual)
  in
  check_occurrences "PreToolUse exact occurrences" expected_all !pre_invocations;
  check_occurrences "PostToolUse exact occurrences" expected_all !post_invocations;
  check_occurrences
    "PostToolUseFailure exact occurrences"
    expected_failure
    !failure_invocations;
  check_occurrences "ToolCalled exact occurrences" expected_all called_invocations;
  check_occurrences "ToolCompleted exact occurrences" expected_all completed_invocations;
  check_occurrences "handler exact occurrences" expected_all !handler_invocations;
  check_occurrences "start callback exact occurrences" expected_all !started_invocations;
  check_occurrences "finish callback exact occurrences" expected_all !finished_invocations;
  check (list string) "result exact occurrences" expected_all result_invocations
;;

let test_tool_exception_still_publishes_tool_completed () =
  Eio_main.run
  @@ fun env ->
  let event_bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:2 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let subscription = Event_bus.subscribe ~config event_bus in
  let raising_tool =
    Tool.create ~name:"boom" ~description:"raises" ~parameters:[] (fun _ ->
      failwith "kaboom")
  in
  let results =
    execute_with_tools_in_env
      env
      ~tools:[ raising_tool ]
      ~hooks:Hooks.empty
      ~event_bus
      [ ToolUse { id = "t1"; name = "boom"; input = `Assoc [] } ]
  in
  (match results with
   | [ result ] ->
     check bool "tool result is error" true (tool_result_outcome_is_error result.outcome);
     check
       bool
       "tool result reports exception"
       true
       (contains_substring ~needle:"Tool 'boom' raised" result.content)
   | _ -> fail "expected exactly one result");
  match
    List.map
      (fun (event : Event_bus.event) -> event.payload)
      (Event_bus.drain subscription)
  with
  | [ ToolCalled { tool_name = "boom"; invocation = called; _ }
    ; ToolCompleted
        { tool_name = "boom"
        ; invocation = completed
        ; output = Error { message; recoverable = false; error_class = Some Unknown }
        ; _
        }
    ] ->
    check
      bool
      "completion event reports exception"
      true
      (contains_substring ~needle:"Tool 'boom' raised" message);
    (* Both events carry the same exact occurrence, while the provider ID
       remains available as a boundary projection. *)
    check
      string
      "ToolCalled carries the provider id"
      "t1"
      (Tool_contract.Invocation.tool_use_id called);
    check
      string
      "ToolCompleted carries the provider id"
      "t1"
      (Tool_contract.Invocation.tool_use_id completed)
  | _ -> fail "expected ToolCalled followed by ToolCompleted error"
;;

let terminal_tool ~name on_execute =
  Tool.create
    ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
    ~name
    ~description:"terminal"
    ~parameters:[]
    (fun _ ->
       on_execute ();
       Ok { Types.content = "terminal-complete"; _meta = None })
;;

let test_terminal_admission_rejects_entire_malformed_batch () =
  Eio_main.run
  @@ fun env ->
  let handler_count = ref 0 in
  let hook_count = ref 0 in
  let before_count = ref 0 in
  let started_count = ref 0 in
  let finished_count = ref 0 in
  let observed_hook_count = ref 0 in
  let hooks =
    { Hooks.empty with
      pre_tool_use =
        Some
          (fun _ ->
            incr hook_count;
            Hooks.Continue)
    }
  in
  let terminal name = terminal_tool ~name (fun () -> incr handler_count) in
  let ordinary =
    Tool.create
      ~descriptor:(Tool.ordinary_descriptor Tool_contract.Concurrent)
      ~name:"ordinary"
      ~description:"ordinary"
      ~parameters:[]
      (fun _ ->
         incr handler_count;
         Ok { Types.content = "ordinary-complete"; _meta = None })
  in
  let run tools tool_uses =
    execute_result_with_tools_in_env
      env
      ~tools
      ~hooks
      ~before_tool_execution:(fun () -> incr before_count)
      ~on_tool_execution_started:(fun ~invocation:_ ~tool_name:_ ~input:_ ->
        incr started_count)
      ~on_tool_execution_finished:
        (fun
          ~invocation:_ ~tool_name:_ ~content:_ ~is_error:_ -> incr finished_count)
      ~on_hook_invoked:(fun ~invocation:_ ~hook_name:_ ~decision:_ ~detail:_ ->
        incr observed_hook_count)
      tool_uses
  in
  let check_rejected label expected_ids = function
    | Error _ -> failf "%s: admission rejection must be model-visible" label
    | Ok (report : Agent_tools.execution_report) ->
      check
        int
        (label ^ " result count")
        (List.length expected_ids)
        (List.length report.completed_results);
      check
        (list string)
        (label ^ " deterministic order")
        expected_ids
        (List.map result_id report.completed_results);
      let contents =
        List.map
          (fun (result : Agent_tools.tool_execution_result) ->
             (match result.outcome with
              | Tool_failed
                  { failure_kind = Validation_error; error_class = Some Deterministic } ->
                ()
              | _ -> failf "%s: expected deterministic Validation_error" label);
             result.content)
          report.completed_results
      in
      (match contents with
       | [] -> failf "%s: expected rejection results" label
       | first :: rest ->
         List.iter
           (fun content -> check string (label ^ " uniform message") first content)
           rest);
      (match report.completion with
       | Agent_tools.Continue_after_batch -> ()
       | Agent_tools.Terminal_completed _ | Agent_tools.Terminal_failed _ ->
         failf "%s: rejected batch cannot complete terminally" label)
  in
  check_rejected
    "terminal plus ordinary"
    [ "terminal-1"; "ordinary-1" ]
    (run
       [ terminal "finish"; ordinary ]
       [ ToolUse { id = "terminal-1"; name = "finish"; input = `Assoc [] }
       ; ToolUse { id = "ordinary-1"; name = "ordinary"; input = `Assoc [] }
       ]);
  check_rejected
    "double terminal"
    [ "terminal-2"; "terminal-3" ]
    (run
       [ terminal "finish-a"; terminal "finish-b" ]
       [ ToolUse { id = "terminal-2"; name = "finish-a"; input = `Assoc [] }
       ; ToolUse { id = "terminal-3"; name = "finish-b"; input = `Assoc [] }
       ]);
  check int "zero handlers" 0 !handler_count;
  check int "zero hooks" 0 !hook_count;
  check int "zero before-tool callbacks/yields" 0 !before_count;
  check int "zero execution starts/fibers" 0 !started_count;
  check int "zero execution finishes" 0 !finished_count;
  check int "zero hook observers" 0 !observed_hook_count
;;

let test_singleton_terminal_reports_exact_invocation_and_recovers () =
  Eio_main.run
  @@ fun env ->
  let tool = terminal_tool ~name:"finish" ignore in
  let tool_uses = [ ToolUse { id = "terminal-1"; name = "finish"; input = `Assoc [] } ] in
  match
    execute_result_with_tools_in_env env ~tools:[ tool ] ~hooks:Hooks.empty tool_uses
  with
  | Error _ -> fail "singleton terminal execution failed"
  | Ok report ->
    let invocation =
      match report.completion with
      | Agent_tools.Continue_after_batch -> fail "terminal success did not stop the batch"
      | Agent_tools.Terminal_failed _ -> fail "terminal success was classified as failure"
      | Agent_tools.Terminal_completed invocation ->
        check
          string
          "exact terminal provider id"
          "terminal-1"
          (Tool_contract.Invocation.tool_use_id invocation);
        invocation
    in
    let recovered =
      Agent_tools.recovered_batch_completion
        ~invocations:[ invocation ]
        [ ToolResult
            { tool_use_id = "terminal-1"
            ; content = "terminal-complete"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    in
    (match recovered with
     | Error error -> fail (Error.to_string error)
     | Ok Agent_tools.Continue_after_batch ->
       fail "settled terminal success was not reconstructed"
     | Ok (Agent_tools.Terminal_failed _) ->
       fail "settled terminal success was reconstructed as failure"
     | Ok (Agent_tools.Terminal_completed invocation) ->
       check
         string
         "recovered exact terminal provider id"
         "terminal-1"
         (Tool_contract.Invocation.tool_use_id invocation))
;;

let test_invalid_terminal_input_remains_correction_capable () =
  Eio_main.run
  @@ fun env ->
  let handler_count = ref 0 in
  let tool =
    Tool.create
      ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
      ~name:"finish"
      ~description:"terminal with typed input"
      ~parameters:
        [ { Types.name = "count"
          ; description = "required count"
          ; param_type = Integer
          ; required = true
          }
        ]
      (fun _ ->
         incr handler_count;
         Ok { Types.content = "must-not-run"; _meta = None })
  in
  match
    execute_result_with_tools_in_env
      env
      ~tools:[ tool ]
      ~hooks:Hooks.empty
      [ ToolUse
          { id = "terminal-invalid"
          ; name = "finish"
          ; input = `Assoc [ "count", `String "not-an-integer" ]
          }
      ]
  with
  | Error _ -> fail "invalid terminal input must remain a model-visible result"
  | Ok report ->
    check int "terminal handler did not run" 0 !handler_count;
    (match report.completed_results with
     | [ { outcome = Tool_failed { failure_kind = Validation_error; _ }; _ } ] -> ()
     | _ -> fail "invalid terminal input was not a typed Validation_error");
    (match report.completion with
     | Agent_tools.Continue_after_batch -> ()
     | Agent_tools.Terminal_completed _ | Agent_tools.Terminal_failed _ ->
       fail "pre-handler validation failure incorrectly closed the terminal boundary")
;;

let () =
  run
    "Tool_execution"
    [ ( "pre_tool_use"
      , [ test_case
            "Block is a typed deterministic failure"
            `Quick
            test_block_is_deterministic_failure
        ; test_case
            "typed approval callback settles pre-tool gate"
            `Quick
            test_pre_tool_approval_callback_settles_gate
        ; test_case
            "approval callback failure is typed"
            `Quick
            test_pre_tool_approval_callback_failure_is_typed
        ; test_case
            "approval reserved exception propagates"
            `Quick
            test_pre_tool_approval_reserved_exception_propagates
        ; test_case
            "approval caller cancellation propagates"
            `Quick
            test_pre_tool_approval_eio_cancellation_propagates
        ] )
    ; ( "routing"
      , [ test_case
            "unknown tools are uniform validation failures with full diagnostics"
            `Quick
            test_unknown_tool_is_uniform_validation_with_full_diagnostics
        ; test_case
            "dispatch passes exact tool invocation"
            `Quick
            test_dispatch_passes_exact_tool_invocation
        ; test_case
            "lifecycle surfaces share exact tool invocation"
            `Quick
            test_lifecycle_surfaces_share_exact_tool_invocation
        ] )
    ; ( "non_tool_use_filtering"
      , [ test_case
            "mixed blocks filtered (#327)"
            `Quick
            test_non_tool_use_blocks_filtered
        ; test_case "only non-ToolUse = empty" `Quick test_only_non_tool_use_blocks
        ] )
    ; ( "scheduling"
      , [ test_case "concurrent batch" `Quick test_concurrent_tools_share_batch
        ; test_case
            "serial tools stay sequential"
            `Quick
            test_serial_tools_run_sequentially
        ; test_case
            "undeclared tools default serial"
            `Quick
            test_undeclared_tools_default_to_sequential
        ; test_case
            "serial barrier splits concurrent batches"
            `Quick
            test_serial_barrier_splits_concurrent_batches
        ] )
    ; ( "event_bus"
      , [ test_case
            "tool exception still publishes ToolCompleted"
            `Quick
            test_tool_exception_still_publishes_tool_completed
        ] )
    ; ( "terminal"
      , [ test_case
            "malformed batches reject before execution"
            `Quick
            test_terminal_admission_rejects_entire_malformed_batch
        ; test_case
            "singleton success reports and recovers exact invocation"
            `Quick
            test_singleton_terminal_reports_exact_invocation_and_recovers
        ; test_case
            "invalid input remains correction-capable"
            `Quick
            test_invalid_terminal_input_remains_correction_capable
        ] )
    ; ( "callbacks"
      , [ test_case
            "lifecycle callback exceptions propagate"
            `Quick
            test_tool_lifecycle_callback_exceptions_propagate
        ; test_case
            "pre-hook observer exception propagates"
            `Quick
            test_pre_hook_observer_exception_propagates
        ; test_case
            "reserved callback exception is not tagged"
            `Quick
            test_reserved_callback_exception_is_not_tagged
        ; test_case
            "post-hook observer propagates after completion"
            `Quick
            test_post_hook_observer_exception_propagates_after_completion
        ; test_case
            "concurrent journal failure retains sibling results"
            `Quick
            test_concurrent_journal_failure_retains_sibling_results
        ] )
    ; ( "hook_failures"
      , [ test_case
            "post-hook failure is a typed agent error"
            `Quick
            test_post_hook_failure_is_typed_agent_error
        ; test_case
            "error hooks run after prior hook failure"
            `Quick
            test_error_hooks_run_after_prior_hook_failure
        ] )
    ; ( "lifecycle_truth"
      , [ test_case
            "Block emits no execution lifecycle"
            `Quick
            test_block_emits_no_execution_lifecycle
        ] )
    ]
;;
