open Alcotest
open Agent_sdk
module Internal = Agent_sdk__
module Runtime_internal = Internal.Execution_runtime
module Event = Internal.Execution_event
module Codec = Internal.Execution_codec_executor
module Journal = Internal.Execution_journal
module Store = Internal.Execution_event_store
module Writer = Internal.Execution_lane_writer
module Settlement = Internal.Execution_tool_settlement
module Agent_scope = Internal.Execution_agent_scope
module Tx = Journal.Transaction

exception Cancel_waiter
exception Cancel_scope
exception Callback_failed
exception Effect_raised

let require_submit = function
  | Ok ticket -> ticket
  | Error error -> fail (Writer.submit_error_to_string error)
;;

let require_ticket = function
  | Ok receipt -> receipt
  | Error error -> fail (Writer.ticket_error_to_string error)
;;

let require_closed = function
  | Ok () -> ()
  | Error error -> fail (Writer.scope_failure_to_string error)
;;

let require_scope = function
  | Ok value -> value
  | Error error -> fail (Writer.scope_failure_to_string error)
;;

let require_agent_scope = function
  | Ok value -> value
  | Error error -> fail (Agent_scope.error_to_string error)
;;

let with_fresh codec dir f =
  require_scope (Writer.run ~codec ~dir (fun ~sw writer -> f sw writer))
;;

let with_existing codec dir f =
  require_scope (Writer.resume ~codec ~dir (fun ~sw writer -> f sw writer))
;;

let require_codec = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let require_runtime = function
  | Ok value -> value
  | Error error -> fail (Runtime_internal.create_error_to_string error)
;;

let with_temp_dir env f =
  Eio.Switch.run (fun codec_sw ->
    let runtime =
      require_runtime
        (Runtime_internal.create
           ~sw:codec_sw
           ~domain_mgr:(Eio.Stdenv.domain_mgr env)
           ~domain_count:1)
    in
    let codec = Codec.of_runtime runtime in
    let native_path = Filename.temp_file "oas-execution-lane-writer-" ".dir" in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Fun.protect
      ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir)
      (fun () -> f codec dir))
;;

let make_dir dir = Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir

let cursor_at cursor seq =
  match Journal.cursor_to_yojson cursor with
  | `Assoc fields ->
    require_codec
      (Journal.cursor_of_yojson
         (`Assoc (("seq", `Int seq) :: List.remove_assoc "seq" fields)))
  | _ -> fail "journal cursor encoder did not return an object"
;;

let check_cursor message expected actual =
  check
    bool
    message
    true
    (Store.Scope_id.equal (Store.cursor_scope_id expected) (Store.cursor_scope_id actual)
     && Store.cursor_seq expected = Store.cursor_seq actual)
;;

let read_complete_page writer ~after ~limit =
  match Writer.read_page writer ~after ~limit () with
  | Error error -> fail (Writer.read_error_to_string error)
  | Ok page ->
    check bool "requested page reaches its frozen watermark" false page.has_more;
    check
      int
      "page cursor reaches its frozen watermark"
      (Journal.cursor_seq page.high_watermark)
      (Journal.cursor_seq page.next_cursor);
    page.events, page.next_cursor
;;

let binding_for ~provider_id =
  let config =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_kind.OpenAI_compat
      ~provider_id
      ~model_id:"lane-writer-model"
      ~base_url:"https://provider.test"
      ()
  in
  Binding_identity.of_provider_config
    ~transport:(Binding_identity.transport_for_call ~injected:false)
    config
  |> require_codec
;;

let provider_attempt_for ~provider_id ordinal =
  require_codec (Event.provider_attempt ~ordinal (binding_for ~provider_id))
;;

let provider_attempt ordinal =
  provider_attempt_for ~provider_id:"lane-writer-test" ordinal
;;

let submit_and_await writer transaction =
  require_ticket (Writer.await (require_submit (Writer.submit writer transaction)))
;;

let check_single_event_group (receipt : _ Writer.receipt) =
  check int "one setup command per durable group" 1 receipt.group_event_count
;;

let open_output writer =
  let opened_run_receipt =
    submit_and_await writer (Tx.start_run ~agent_name:"lane-writer" ())
  in
  let run, opened_run = opened_run_receipt.value in
  let opened_turn_receipt =
    submit_and_await
      writer
      (Tx.open_node
         ~run
         ~parent:(Journal.run_root run)
         ~kind:(Event.Agent_turn { ordinal = 0 })
         ())
  in
  let turn, opened_turn = opened_turn_receipt.value in
  let opened_attempt_receipt =
    submit_and_await writer (Tx.open_node ~run ~parent:turn ~kind:(provider_attempt 0) ())
  in
  let attempt, opened_attempt = opened_attempt_receipt.value in
  let opened_output_receipt =
    submit_and_await
      writer
      (Tx.open_node
         ~run
         ~parent:attempt
         ~kind:(Event.Output_block { ordinal = 0; block_kind = Event.Thinking_block })
         ())
  in
  let output, opened_output = opened_output_receipt.value in
  check_single_event_group opened_run_receipt;
  check_single_event_group opened_turn_receipt;
  check_single_event_group opened_attempt_receipt;
  check_single_event_group opened_output_receipt;
  ( run
  , output
  , opened_output_receipt.through
  , [ opened_run; opened_turn; opened_attempt; opened_output ] )
;;

let delta_transaction output index =
  Tx.update_node ~node:output (Event.Output_delta (`Assoc [ "index", `Int index ]))
;;

let test_effect_attempt_and_settlement_survive_restart () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let restart_pairs = ref None in
    let result =
      Types.ToolResult
        { tool_use_id = "call-0"
        ; content = "done"
        ; outcome = Types.Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    in
    with_fresh codec dir (fun _sw writer ->
      let value transaction = (submit_and_await writer transaction).value in
      let run, _ = value (Tx.start_run ~agent_name:"effect" ()) in
      let turn, _ =
        value
          (Tx.open_node
             ~run
             ~parent:(Journal.run_root run)
             ~kind:(Event.Agent_turn { ordinal = 1 })
             ())
      in
      let provider, _ =
        value (Tx.open_node ~run ~parent:turn ~kind:(provider_attempt 0) ())
      in
      let open_invocation planned_index =
        let schedule : Tool_contract.schedule =
          { planned_index
          ; batch_index = 0
          ; batch_size = 2
          ; execution_mode = Tool_contract.Serial
          }
        in
        let tool_use_id = Printf.sprintf "call-%d" planned_index in
        let invocation =
          Tool_contract.Invocation.create
            ~tool_use_id
            ~turn:1
            ~schedule
            ~completion:Tool_contract.Continue_after_success
        in
        let receipt =
          submit_and_await
            writer
            (Tx.open_tool_invocation
               ~run
               ~provider_attempt:provider
               ~invocation
               ~tool_name:"effect"
               ~input:`Null
               ())
        in
        let node, events = receipt.value in
        check int "open and materialize in one group" 2 (List.length events);
        check int "one durable producer group" 2 receipt.group_event_count;
        node, invocation
      in
      let authority (node, _invocation) =
        match Settlement.rebind ~writer ~invocation_node:node with
        | Ok durable -> durable.authority
        | Error _ -> fail "durable invocation authority rejected exact identity"
      in
      let first_pair = open_invocation 0 in
      let first = authority first_pair in
      let seq () = Journal.cursor_seq (Result.get_ok (Writer.current_cursor writer)) in
      let before_duplicate = seq () in
      let first_node, first_invocation = first_pair in
      (match
         Writer.await
           (require_submit
              (Writer.submit
                 writer
                 (Tx.open_tool_invocation
                    ~run
                    ~provider_attempt:provider
                    ~invocation:first_invocation
                    ~tool_name:"effect"
                    ~input:`Null
                    ())))
       with
       | Error
           (Writer.Transaction_rejected
              (Journal.Invariant_violation (Journal.Occurrence_already_opened existing)))
         when Event.Node_id.equal existing first_node -> ()
       | Ok _ | Error _ -> fail "duplicate tool occurrence was accepted");
      check int "duplicate producer is atomic" before_duplicate (seq ());
      let before_rejected_producer = seq () in
      let wrong_schedule : Tool_contract.schedule =
        { planned_index = 99
        ; batch_index = 1
        ; batch_size = 1
        ; execution_mode = Tool_contract.Serial
        }
      in
      let wrong_invocation =
        Tool_contract.Invocation.create
          ~tool_use_id:"wrong-turn"
          ~turn:2
          ~schedule:wrong_schedule
          ~completion:Tool_contract.Continue_after_success
      in
      (match
         Writer.await
           (require_submit
              (Writer.submit
                 writer
                 (Tx.open_tool_invocation
                    ~run
                    ~provider_attempt:provider
                    ~invocation:wrong_invocation
                    ~tool_name:"effect"
                    ~input:`Null
                    ())))
       with
       | Error
           (Writer.Transaction_rejected
              (Journal.Invalid_argument
                 "tool invocation turn does not match its provider attempt")) -> ()
       | Ok _ | Error _ -> fail "mismatched invocation turn was accepted");
      check int "rejected producer is atomic" before_rejected_producer (seq ());
      let before_seq = seq () in
      (match
         Settlement.execute first ~invoke:(fun () ->
           check int "attempt durable" (before_seq + 1) (seq ());
           result)
       with
       | Ok (Settlement.Executed (_committed, through, event_count)) ->
         check int "one settlement batch" 3 event_count;
         check int "four durable events" (before_seq + 4) (Journal.cursor_seq through)
       | Ok (Settlement.Replayed _) | Error _ -> fail "fresh effect did not settle");
      let cancelled_pair = open_invocation 2 in
      let cancelled = authority cancelled_pair in
      let cancelled_result =
        Types.ToolResult
          { tool_use_id = "call-2"
          ; content = "settled after cancellation"
          ; outcome = Types.Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      in
      (match
         Eio.Cancel.sub (fun cancellation ->
           match
             Settlement.execute cancelled ~invoke:(fun () ->
               Eio.Cancel.cancel cancellation Cancel_scope;
               cancelled_result)
           with
           | Ok (Settlement.Executed _) -> ()
           | Ok (Settlement.Replayed _) | Error _ ->
             fail "post-effect cancellation lost settlement")
       with
       | () -> ()
       | exception Eio.Cancel.Cancelled Cancel_scope -> ()
       | exception exn -> raise exn);
      let pre_effect_cancel_pair = open_invocation 3 in
      let pre_effect_cancel = authority pre_effect_cancel_pair in
      let pre_effect_cancel_invoked = ref false in
      let pre_effect_cancel_result =
        Types.ToolResult
          { tool_use_id = "call-3"
          ; content = "effect ran after committed-attempt cancellation"
          ; outcome = Types.Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      in
      (match
         Eio.Cancel.sub (fun cancellation ->
           match
             Settlement.For_testing.execute_with_attempt_after_attempt_committed
               pre_effect_cancel
               ~after_attempt_committed:(fun () ->
                 Eio.Cancel.cancel cancellation Cancel_scope)
               ~invoke:(fun _attempt ->
                 pre_effect_cancel_invoked := true;
                 pre_effect_cancel_result)
           with
           | Ok (Settlement.Executed _) -> ()
           | Ok (Settlement.Replayed _) | Error _ ->
             fail "pre-effect cancellation lost settlement")
       with
       | () -> ()
       | exception Eio.Cancel.Cancelled Cancel_scope -> ()
       | exception exn -> raise exn);
      check
        bool
        "committed attempt enters effect without a cancellation gap"
        true
        !pre_effect_cancel_invoked;
      let second_pair = open_invocation 1 in
      let second = authority second_pair in
      match Settlement.execute second ~invoke:(fun () -> raise Effect_raised) with
      | exception Effect_raised ->
        restart_pairs
        := Some
             ( first_pair
             , second_pair
             , cancelled_pair
             , cancelled_result
             , pre_effect_cancel_pair
             , pre_effect_cancel_result )
      | Ok _ | Error _ -> fail "effect exception did not propagate");
    let ( first_pair
        , second_pair
        , cancelled_pair
        , cancelled_result
        , pre_effect_cancel_pair
        , pre_effect_cancel_result )
      =
      Option.get !restart_pairs
    in
    with_existing codec dir (fun _sw writer ->
      ignore (require_scope (Writer.await_ready writer));
      let authority (node, _invocation) =
        (Result.get_ok (Settlement.rebind ~writer ~invocation_node:node)).authority
      in
      let never () = fail "effect reran" in
      (match Settlement.execute (authority first_pair) ~invoke:never with
       | Ok (Settlement.Replayed replayed) when replayed = result -> ()
       | Ok (Settlement.Replayed _ | Settlement.Executed _) | Error _ ->
         fail "restart lost settlement");
      (match Settlement.execute (authority cancelled_pair) ~invoke:never with
       | Ok (Settlement.Replayed settled) when settled = cancelled_result -> ()
       | Ok (Settlement.Replayed _ | Settlement.Executed _) | Error _ ->
         fail "post-effect cancellation left no durable receipt");
      (match Settlement.execute (authority pre_effect_cancel_pair) ~invoke:never with
       | Ok (Settlement.Replayed settled) when settled = pre_effect_cancel_result -> ()
       | Ok (Settlement.Replayed _ | Settlement.Executed _) | Error _ ->
         fail "committed-attempt cancellation poisoned an effect that ran");
      match Settlement.execute (authority second_pair) ~invoke:never with
      | Error Settlement.Effect_outcome_unknown -> ()
      | Ok _ | Error _ -> fail "restart did not fence unknown effect"))
;;

let test_structural_occurrence_identity_is_parent_local () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let value transaction = (submit_and_await writer transaction).value in
      let seq () = Writer.current_cursor writer |> Result.get_ok |> Journal.cursor_seq in
      let expect_rejected_without_events label transaction matches =
        let before = seq () in
        (match Writer.await (require_submit (Writer.submit writer transaction)) with
         | Error (Writer.Transaction_rejected (Journal.Invariant_violation violation))
           when matches violation -> ()
         | Error error -> fail (label ^ ": " ^ Writer.ticket_error_to_string error)
         | Ok _ -> fail (label ^ ": duplicate occurrence was accepted"));
        check int (label ^ " is atomic") before (seq ())
      in
      let run, _ = value (Tx.start_run ~agent_name:"occurrence" ()) in
      let turn_0, _ =
        value
          (Tx.open_node
             ~run
             ~parent:(Journal.run_root run)
             ~kind:(Event.Agent_turn { ordinal = 0 })
             ())
      in
      expect_rejected_without_events
        "duplicate turn"
        (Tx.open_node
           ~run
           ~parent:(Journal.run_root run)
           ~kind:(Event.Agent_turn { ordinal = 0 })
           ())
        (function
          | Journal.Occurrence_already_opened existing ->
            Event.Node_id.equal existing turn_0
          | _ -> false);
      let turn_1, _ =
        value
          (Tx.open_node
             ~run
             ~parent:(Journal.run_root run)
             ~kind:(Event.Agent_turn { ordinal = 1 })
             ())
      in
      let provider_0, _ =
        value (Tx.open_node ~run ~parent:turn_0 ~kind:(provider_attempt 0) ())
      in
      expect_rejected_without_events
        "duplicate provider ordinal ignores diagnostic binding"
        (Tx.open_node
           ~run
           ~parent:turn_0
           ~kind:(provider_attempt_for ~provider_id:"different-binding" 0)
           ())
        (function
          | Journal.Occurrence_already_opened existing ->
            Event.Node_id.equal existing provider_0
          | _ -> false);
      let provider_1, _ =
        value (Tx.open_node ~run ~parent:turn_1 ~kind:(provider_attempt 0) ())
      in
      let schedule : Tool_contract.schedule =
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Tool_contract.Serial
        }
      in
      let input = `Assoc [ "value", `Int 7 ] in
      let occurrence_0 =
        Tool_contract.Invocation.create
          ~tool_use_id:"call"
          ~turn:0
          ~schedule
          ~completion:Tool_contract.Continue_after_success
      in
      let tool_0, _ =
        value
          (Tx.open_tool_invocation
             ~run
             ~provider_attempt:provider_0
             ~invocation:occurrence_0
             ~tool_name:"effect"
             ~input
             ())
      in
      expect_rejected_without_events
        "exact tool duplicate"
        (Tx.open_tool_invocation
           ~run
           ~provider_attempt:provider_0
           ~invocation:occurrence_0
           ~tool_name:"effect"
           ~input
           ())
        (function
        | Journal.Occurrence_already_opened existing ->
          Event.Node_id.equal existing tool_0
        | _ -> false);
      let changed_schedule : Tool_contract.schedule =
        { schedule with
          batch_index = 1
        ; batch_size = 2
        ; execution_mode = Tool_contract.Concurrent
        }
      in
      let conflicts =
        [ ( "tool schedule conflict"
          , Tool_contract.Invocation.create
              ~tool_use_id:"call"
              ~turn:0
              ~schedule:changed_schedule
              ~completion:Tool_contract.Continue_after_success
          , "effect"
          , input )
        ; ( "tool id conflict"
          , Tool_contract.Invocation.create
              ~tool_use_id:"other-call"
              ~turn:0
              ~schedule
              ~completion:Tool_contract.Continue_after_success
          , "effect"
          , input )
        ; "tool name conflict", occurrence_0, "other-effect", input
        ; "tool input conflict", occurrence_0, "effect", `Assoc [ "value", `Int 8 ]
        ]
      in
      List.iter
        (fun (label, invocation, tool_name, input) ->
           expect_rejected_without_events
             label
             (Tx.open_tool_invocation
                ~run
                ~provider_attempt:provider_0
                ~invocation
                ~tool_name
                ~input
                ())
             (function
             | Journal.Tool_occurrence_conflict { parent; planned_index = 0; existing } ->
               Event.Node_id.equal parent provider_0
               && Event.Node_id.equal existing tool_0
             | _ -> false))
        conflicts;
      expect_rejected_without_events
        "first raw tool open cannot bypass atomic producer"
        (Tx.open_node
           ~run
           ~parent:provider_1
           ~kind:
             (Event.Tool_invocation
                { provider_tool_use_id = Some "raw"
                ; tool_name = "raw"
                ; schedule
                ; completion = Tool_contract.Continue_after_success
                })
           ())
        (function
          | Journal.Tool_invocation_requires_atomic_open -> true
          | _ -> false);
      let occurrence_1 =
        Tool_contract.Invocation.create
          ~tool_use_id:"call"
          ~turn:1
          ~schedule
          ~completion:Tool_contract.Continue_after_success
      in
      ignore
        (value
           (Tx.open_tool_invocation
              ~run
              ~provider_attempt:provider_1
              ~invocation:occurrence_1
              ~tool_name:"effect"
              ~input
              ()));
      let attempt, _ = value (Tx.begin_tool_attempt ~invocation:tool_0 ()) in
      let child_run, _ =
        value (Tx.start_run ~parent_attempt:attempt ~agent_name:"child" ())
      in
      let child_turn, _ =
        value
          (Tx.open_node
             ~run:child_run
             ~parent:(Journal.run_root child_run)
             ~kind:(Event.Agent_turn { ordinal = 0 })
             ())
      in
      let child_provider, _ =
        value
          (Tx.open_node ~run:child_run ~parent:child_turn ~kind:(provider_attempt 0) ())
      in
      let child_invocation, _ =
        value
          (Tx.open_tool_invocation
             ~run:child_run
             ~provider_attempt:child_provider
             ~invocation:
               (Tool_contract.Invocation.create
                  ~tool_use_id:"child"
                  ~turn:0
                  ~schedule
                  ~completion:Tool_contract.Continue_after_success)
             ~tool_name:"child-effect"
             ~input:`Null
             ())
      in
      let locator run_id node_id =
        `Assoc [ "version", `Int 1; "run_id", `String run_id; "node_id", `String node_id ]
      in
      let root_scope =
        `Assoc
          [ "version", `Int 1
          ; "run_id", `String (Event.Run_id.to_string (Journal.run_id run))
          ]
        |> Agent_scope.scope_locator_of_yojson
        |> require_codec
        |> Agent_scope.resume ~writer ~agent_name:"occurrence"
        |> require_agent_scope
      in
      let foreign =
        locator
          (Event.Run_id.to_string (Journal.run_id child_run))
          (Event.Node_id.to_string child_invocation)
        |> Agent_scope.invocation_locator_of_yojson
        |> require_codec
      in
      match Agent_scope.rebind_invocation root_scope foreign with
      | Error Agent_scope.Invocation_locator_mismatch -> ()
      | Error error -> fail (Agent_scope.error_to_string error)
      | Ok _ -> fail "foreign run invocation rebound into root scope"))
;;

let test_agent_scope_owns_effect_topology () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let scope_locator_json = ref None in
    let invocation_locator_json = ref None in
    let calls = ref 0 in
    let settled_before_observer = ref false in
    with_fresh codec dir (fun _sw writer ->
      let scope = require_agent_scope (Agent_scope.start ~writer ~agent_name:"agent") in
      scope_locator_json
      := Some (Agent_scope.scope_locator_to_yojson (Agent_scope.scope_locator scope));
      let before_cancelled =
        Writer.current_cursor writer |> Result.get_ok |> Journal.cursor_seq
      in
      (match
         Eio.Cancel.sub (fun cancellation ->
           Eio.Cancel.cancel cancellation Cancel_scope;
           ignore (Agent_scope.open_turn scope ~ordinal:99))
       with
       | exception Eio.Cancel.Cancelled Cancel_scope -> ()
       | () -> fail "pre-cancelled topology mutation returned"
       | exception exn -> raise exn);
      check
        int
        "pre-cancelled topology mutation admitted no event"
        before_cancelled
        (Writer.current_cursor writer |> Result.get_ok |> Journal.cursor_seq);
      let before = cursor_at (Result.get_ok (Writer.current_cursor writer)) 0 in
      let turn = require_agent_scope (Agent_scope.open_turn scope ~ordinal:3) in
      let provider =
        require_agent_scope
          (Agent_scope.open_provider_attempt
             turn
             ~ordinal:0
             (binding_for ~provider_id:"scope-provider"))
      in
      let schedule : Tool_contract.schedule =
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Tool_contract.Serial
        }
      in
      let wrong_turn =
        Tool_contract.Invocation.create
          ~tool_use_id:""
          ~turn:4
          ~schedule
          ~completion:Tool_contract.Continue_after_success
      in
      (match
         Agent_scope.open_invocation
           provider
           ~invocation:wrong_turn
           ~tool_name:"effect"
           ~input:`Null
       with
       | Error _ -> ()
       | Ok _ -> fail "mismatched invocation turn entered the scope");
      check
        int
        "rejected invocation left no partial node"
        3
        (Writer.current_cursor writer |> Result.get_ok |> Journal.cursor_seq);
      let exact_invocation =
        Tool_contract.Invocation.create
          ~tool_use_id:""
          ~turn:3
          ~schedule
          ~completion:Tool_contract.Continue_after_success
      in
      let invocation =
        require_agent_scope
          (Agent_scope.open_invocation
             provider
             ~invocation:exact_invocation
             ~tool_name:"effect"
             ~input:(`Assoc [ "value", `Int 7 ]))
      in
      invocation_locator_json
      := Some
           (Agent_scope.invocation_locator_to_yojson
              (Agent_scope.invocation_locator invocation));
      let before_effect =
        Writer.current_cursor writer |> Result.get_ok |> Journal.cursor_seq
      in
      (match
         Agent_scope.execute_phased
           invocation
           ~invoke:(fun ~start_child ~tool_name:_ ~input:_ ->
             incr calls;
             let child = require_agent_scope (start_child ~agent_name:"child-agent") in
             require_agent_scope (Agent_scope.finish child Event.Succeeded);
             ( ("done", Types.Tool_succeeded)
             , fun () ->
                 let observed =
                   Writer.current_cursor writer |> Result.get_ok |> Journal.cursor_seq
                 in
                 check int "observer sees durable ToolResult" (before_effect + 6) observed;
                 settled_before_observer := true ))
       with
       | Ok (Agent_scope.Executed _) -> ()
       | Ok (Agent_scope.Replayed _) -> fail "fresh scoped effect was replayed"
       | Error error -> fail (Agent_scope.error_to_string error));
      check int "scoped effect call count" 1 !calls;
      check bool "post-effect observer ran after settlement" true !settled_before_observer;
      let abort_result =
        match
          Eio.Cancel.sub (fun cancellation ->
            Eio.Cancel.cancel cancellation Cancel_scope;
            Agent_scope.abort
              scope
              (Agent_scope.Cancelled { reason = Some "scope test complete"; data = None }))
        with
        | result -> result
        | exception Eio.Cancel.Cancelled Cancel_scope ->
          fail "cancelled cleanup context lost the durable abort receipt"
        | exception exn -> raise exn
      in
      require_agent_scope abort_result;
      let events, through = read_complete_page writer ~after:before ~limit:14 in
      check int "closed scope event count" 14 (List.length events);
      check int "closed scope cursor" 14 (Journal.cursor_seq through);
      let tool_attempt =
        List.find_map
          (fun event ->
             match Event.payload event with
             | Event.Node_opened node when Event.node_kind node = Event.Tool_attempt ->
               Some node
             | _ -> None)
          events
        |> Option.get
      in
      let child_root =
        List.find_map
          (fun event ->
             match Event.payload event with
             | Event.Node_opened node ->
               (match Event.node_kind node with
                | Event.Agent_run { agent_name = "child-agent" } -> Some node
                | _ -> None)
             | _ -> None)
          events
        |> Option.get
      in
      check
        bool
        "child run is rooted beneath exact tool attempt"
        true
        (Option.equal
           Event.Node_id.equal
           (Event.parent_node_id child_root)
           (Some (Event.node_id tool_attempt)));
      match List.map Event.payload events with
      | Event.Node_opened root
        :: Event.Node_opened turn_node
        :: Event.Node_opened provider_node
        :: Event.Node_opened invocation_node
        :: Event.Node_updated { update = Event.Tool_input_snapshot input; _ }
        :: _ ->
        (match
           ( Event.node_kind root
           , Event.node_kind turn_node
           , Event.node_kind provider_node
           , Event.node_kind invocation_node
           , input )
         with
         | ( Event.Agent_run { agent_name = "agent" }
           , Event.Agent_turn { ordinal = 3 }
           , Event.Provider_attempt { ordinal = 0; _ }
           , Event.Tool_invocation
               { provider_tool_use_id = Some ""; tool_name = "effect"; _ }
           , Types.ToolUse
               { id = ""; name = "effect"; input = `Assoc [ ("value", `Int 7) ] } ) -> ()
         | _ -> fail "scope did not retain exact typed topology")
      | _ -> fail "scope did not write its topology before the effect");
    with_existing codec dir (fun _sw writer ->
      ignore (require_scope (Writer.await_ready writer));
      let locator =
        Option.get !scope_locator_json
        |> Agent_scope.scope_locator_of_yojson
        |> require_codec
      in
      (match Agent_scope.resume ~writer ~agent_name:"other-agent" locator with
       | Error
           (Agent_scope.Agent_identity_mismatch
              { expected = "agent"; actual = "other-agent" }) -> ()
       | Error error -> fail (Agent_scope.error_to_string error)
       | Ok _ -> fail "scope resumed under the wrong Agent identity");
      let scope =
        require_agent_scope (Agent_scope.resume ~writer ~agent_name:"agent" locator)
      in
      let invocation =
        Option.get !invocation_locator_json
        |> Agent_scope.invocation_locator_of_yojson
        |> require_codec
        |> Agent_scope.rebind_invocation scope
        |> require_agent_scope
      in
      (match
         Agent_scope.execute
           invocation
           ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ -> fail "effect reran")
       with
       | Ok (Agent_scope.Replayed replayed) ->
         check string "reopened result content" "done" replayed.content;
         check
           bool
           "reopened result outcome"
           true
           (replayed.outcome = Types.Tool_succeeded)
       | Ok (Agent_scope.Executed _) -> fail "reopened scope executed effect twice"
       | Error error -> fail (Agent_scope.error_to_string error));
      check int "reopened scope preserves call count" 1 !calls))
;;

let test_agent_scope_executes_pending_after_restart () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let scope_json, invocation_json = ref None, ref None in
    let expected_input = `Assoc [ "path", `String "durable" ] in
    with_fresh codec dir (fun _sw writer ->
      let scope = require_agent_scope (Agent_scope.start ~writer ~agent_name:"agent") in
      scope_json
      := Some (Agent_scope.scope_locator_to_yojson (Agent_scope.scope_locator scope));
      let turn = require_agent_scope (Agent_scope.open_turn scope ~ordinal:0) in
      let provider =
        require_agent_scope
          (Agent_scope.open_provider_attempt
             turn
             ~ordinal:0
             (binding_for ~provider_id:"pending-provider"))
      in
      let schedule : Tool_contract.schedule =
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Tool_contract.Serial
        }
      in
      let invocation =
        require_agent_scope
          (Agent_scope.open_invocation
             provider
             ~invocation:
               (Tool_contract.Invocation.create
                  ~tool_use_id:"pending"
                  ~turn:0
                  ~schedule
                  ~completion:Tool_contract.Continue_after_success)
             ~tool_name:"durable-tool"
             ~input:expected_input)
      in
      invocation_json
      := Some
           (Agent_scope.invocation_locator_to_yojson
              (Agent_scope.invocation_locator invocation)));
    with_existing codec dir (fun _sw writer ->
      ignore (require_scope (Writer.await_ready writer));
      let scope =
        Option.get !scope_json
        |> Agent_scope.scope_locator_of_yojson
        |> require_codec
        |> Agent_scope.resume ~writer ~agent_name:"agent"
        |> require_agent_scope
      in
      let invocation =
        Option.get !invocation_json
        |> Agent_scope.invocation_locator_of_yojson
        |> require_codec
        |> Agent_scope.rebind_invocation scope
        |> require_agent_scope
      in
      (match
         Agent_scope.execute invocation ~invoke:(fun ~start_child:_ ~tool_name ~input ->
           check string "rebound tool name" "durable-tool" tool_name;
           check bool "rebound tool input" true (Yojson.Safe.equal input expected_input);
           "done", Types.Tool_succeeded)
       with
       | Ok (Agent_scope.Executed ({ content = "done"; _ }, _, _)) -> ()
       | Ok (Agent_scope.Executed _ | Agent_scope.Replayed _) ->
         fail "pending command mismatch"
       | Error error -> fail (Agent_scope.error_to_string error));
      require_agent_scope
        (Agent_scope.abort
           scope
           (Agent_scope.Cancelled
              { reason = Some "pending command test complete"; data = None }))))
;;

let rec await_reconciliation_phase writer =
  let observed = Writer.stats writer in
  match observed.admission, observed.worker_phase with
  | Writer.Failed failure, _ -> fail (Writer.scope_failure_to_string failure)
  | Writer.Closed, _ -> fail "writer closed before reconciliation was observed"
  | ( (Writer.Accepting | Writer.Draining)
    , (Writer.Reconciling_group | Writer.Awaiting_reconciliation_wake) ) -> ()
  | ( (Writer.Accepting | Writer.Draining)
    , (Writer.Starting | Writer.Idle | Writer.Committing_group) ) ->
    Eio.Fiber.yield ();
    await_reconciliation_phase writer
;;

let rec await_reconciliation_wait writer ~outcome_count =
  let observed = Writer.stats writer in
  match observed.admission, observed.worker_phase, observed.current_reconciliation with
  | Writer.Failed failure, _, _ -> fail (Writer.scope_failure_to_string failure)
  | Writer.Closed, _, _ -> fail "writer closed before reconciliation wait"
  | ( (Writer.Accepting | Writer.Draining)
    , Writer.Awaiting_reconciliation_wake
    , Some evidence )
    when evidence.outcome_count = outcome_count -> observed
  | ( (Writer.Accepting | Writer.Draining)
    , ( Writer.Starting
      | Writer.Idle
      | Writer.Committing_group
      | Writer.Reconciling_group
      | Writer.Awaiting_reconciliation_wake )
    , _ ) ->
    Eio.Fiber.yield ();
    await_reconciliation_wait writer ~outcome_count
;;

let test_single_command_commits_and_close_drains () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let ticket =
        require_submit (Writer.submit writer (Tx.start_run ~agent_name:"single" ()))
      in
      Writer.close writer;
      (match Writer.submit writer (Tx.start_run ~agent_name:"late" ()) with
       | Error Writer.Admission_closed -> ()
       | Error error -> fail (Writer.submit_error_to_string error)
       | Ok _ -> fail "closed admission accepted another transaction");
      let receipt = require_ticket (Writer.await ticket) in
      check int "single event cursor" 1 (Journal.cursor_seq receipt.through);
      check int "single event group" 1 receipt.group_event_count;
      require_closed (Writer.await_closed writer);
      let observed = Writer.stats writer in
      (match observed.admission with
       | Writer.Closed -> ()
       | Writer.Accepting | Writer.Draining | Writer.Failed _ ->
         fail "drained actor did not reach closed admission");
      check int "accepted" 1 observed.accepted;
      check int "settled" 1 observed.settled;
      check int "empty queue" 0 observed.queue_depth;
      Writer.close writer;
      require_closed (Writer.await_closed writer)))
;;

let test_ready_set_is_one_fifo_durable_group () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let _run, output, setup_through, setup_events = open_output writer in
      check bool "setup values are exact events" true (List.length setup_events = 4);
      let tickets : Event.t Writer.ticket list =
        List.init 32 (fun index ->
          require_submit (Writer.submit writer (delta_transaction output index)))
      in
      let receipts : Event.t Writer.receipt list =
        List.map (fun ticket -> require_ticket (Writer.await ticket)) tickets
      in
      let expected_through = Journal.cursor_seq setup_through + 32 in
      List.iter
        (fun (receipt : Event.t Writer.receipt) ->
           check
             int
             "shared group cursor"
             expected_through
             (Journal.cursor_seq receipt.Writer.through);
           check int "shared group size" 32 receipt.Writer.group_event_count)
        receipts;
      let events, through = read_complete_page writer ~after:setup_through ~limit:32 in
      check int "replayed ready set" 32 (List.length events);
      check int "replayed cursor" expected_through (Journal.cursor_seq through);
      check
        bool
        "FIFO receipts equal durable replay"
        true
        (List.equal
           Event.equal
           (List.map (fun receipt -> receipt.Writer.value) receipts)
           events);
      let observed = Writer.stats writer in
      check int "five physical groups" 5 observed.committed_groups;
      check int "all commands observed" 36 observed.committed_commands;
      check int "all events observed" 36 observed.committed_events;
      require_closed (Writer.close_and_await writer)))
;;

let test_semantic_rejection_does_not_poison_ready_group () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let run, output, setup_through, _events = open_output writer in
      let first = require_submit (Writer.submit writer (delta_transaction output 0)) in
      let rejected =
        require_submit (Writer.submit writer (Tx.finish_run ~run Event.Succeeded))
      in
      let second = require_submit (Writer.submit writer (delta_transaction output 1)) in
      ignore (require_ticket (Writer.await first));
      (match Writer.await rejected with
       | Error
           (Writer.Transaction_rejected
              (Journal.Invariant_violation (Journal.Node_has_open_children node_id))) ->
         check
           bool
           "exact rejected root"
           true
           (Event.Node_id.equal node_id (Journal.run_root run))
       | Error error -> fail (Writer.ticket_error_to_string error)
       | Ok _ -> fail "invalid finish_run entered the durable group");
      ignore (require_ticket (Writer.await second));
      let events, through = read_complete_page writer ~after:setup_through ~limit:2 in
      check int "only valid events committed" 2 (List.length events);
      check int "cursor excludes rejected event" 6 (Journal.cursor_seq through);
      let observed = Writer.stats writer in
      check int "all admitted tickets settled" 7 observed.settled;
      check int "five physical groups" 5 observed.committed_groups;
      check int "only valid commands committed" 6 observed.committed_commands;
      require_closed (Writer.close_and_await writer)))
;;

let test_concurrent_submit_and_close_linearize_without_loss () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let _run, output, setup_through, setup_events = open_output writer in
      let accepted_before_race =
        require_submit (Writer.submit writer (delta_transaction output (-1)))
      in
      let race_size = 32 in
      let submissions = Array.make race_size None in
      let start, release_start = Eio.Promise.create () in
      Eio.Switch.run (fun race_sw ->
        Array.iteri
          (fun index _ ->
             Eio.Fiber.fork ~sw:race_sw (fun () ->
               Eio.Promise.await start;
               submissions.(index)
               <- Some (Writer.submit writer (delta_transaction output index))))
          submissions;
        Eio.Fiber.fork ~sw:race_sw (fun () ->
          Eio.Promise.await start;
          Writer.close writer);
        Eio.Promise.resolve release_start ());
      require_closed (Writer.await_closed writer);
      let accepted_tickets : Event.t Writer.ticket list ref =
        ref [ accepted_before_race ]
      in
      let rejected = ref 0 in
      Array.iter
        (function
          | Some (Ok ticket) -> accepted_tickets := ticket :: !accepted_tickets
          | Some (Error Writer.Admission_closed) -> incr rejected
          | Some (Error error) -> fail (Writer.submit_error_to_string error)
          | None -> fail "racing submitter did not publish its linearized result")
        submissions;
      check
        int
        "every racing submission linearized"
        race_size
        (List.length !accepted_tickets - 1 + !rejected);
      let receipts =
        List.map (fun ticket -> require_ticket (Writer.await ticket)) !accepted_tickets
      in
      let events, through =
        read_complete_page writer ~after:setup_through ~limit:(List.length receipts)
      in
      let receipt_events =
        List.map (fun receipt -> receipt.Writer.value) receipts
        |> List.sort (fun left right -> Int.compare (Event.seq left) (Event.seq right))
      in
      check
        bool
        "every accepted mutation is replayed exactly once"
        true
        (List.equal Event.equal receipt_events events);
      check
        int
        "replay cursor covers every accepted mutation"
        (Journal.cursor_seq setup_through + List.length receipts)
        (Journal.cursor_seq through);
      let observed = Writer.stats writer in
      let expected_accepted = List.length setup_events + List.length receipts in
      check int "exact accepted command count" expected_accepted observed.accepted;
      check int "accepted commands all settled" observed.accepted observed.settled;
      check int "drained queue is empty" 0 observed.queue_depth;
      check int "drained in-flight set is empty" 0 observed.in_flight_commands;
      check
        int
        "accepted commands are all durable"
        observed.accepted
        observed.committed_commands;
      check
        int
        "one event per accepted command"
        observed.committed_commands
        observed.committed_events;
      match Writer.submit writer (Tx.start_run ~agent_name:"after-race" ()) with
      | Error Writer.Admission_closed -> ()
      | Error error -> fail (Writer.submit_error_to_string error)
      | Ok _ -> fail "closed writer accepted a post-linearization transaction"))
;;

let test_cancelled_waiter_does_not_cancel_ticket () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let ticket =
        require_submit (Writer.submit writer (Tx.start_run ~agent_name:"waiter" ()))
      in
      let waiter_cancelled =
        match
          Eio.Cancel.sub (fun context ->
            Eio.Cancel.cancel context Cancel_waiter;
            ignore (Writer.await ticket);
            false)
        with
        | value -> value
        | exception Eio.Cancel.Cancelled Cancel_waiter -> true
        | exception exn -> raise exn
      in
      check bool "awaiting fiber was cancelled" true waiter_cancelled;
      let receipt = require_ticket (Writer.await ticket) in
      check int "accepted mutation survived waiter" 1 (Journal.cursor_seq receipt.through);
      require_closed (Writer.close_and_await writer)))
;;

let test_supervisor_cancellation_settles_accepted_ticket () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let ticket = ref None in
    (match
       with_fresh codec dir (fun sw writer ->
         ticket
         := Some
              (require_submit
                 (Writer.submit writer (Tx.start_run ~agent_name:"cancelled-scope" ())));
         Eio.Switch.fail sw Cancel_scope)
     with
     | () -> fail "failed supervisor switch returned normally"
     | exception Cancel_scope -> ()
     | exception exn -> raise exn);
    match Writer.await (Option.get !ticket) with
    | Error (Writer.Scope_failed (Writer.Supervisor_cancelled Cancel_scope)) -> ()
    | Error error -> fail (Writer.ticket_error_to_string error)
    | Ok _ -> fail "cancelled supervisor reported a durable ticket")
;;

let test_initialization_failure_is_scope_local () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec root ->
    make_dir root;
    let missing = Eio.Path.(root / "missing" / "scope") in
    let healthy = Eio.Path.(root / "healthy") in
    make_dir healthy;
    let failed, healthy =
      Eio.Fiber.pair
        (fun () ->
           Writer.run ~codec ~dir:missing (fun ~sw:_ failed_writer ->
             match Writer.await_ready failed_writer with
             | Error (Writer.Initialization_failed _) -> ()
             | Error error -> fail (Writer.scope_failure_to_string error)
             | Ok () -> fail "missing durability directory became ready"))
        (fun () ->
           Writer.run ~codec ~dir:healthy (fun ~sw:_ healthy_writer ->
             require_scope (Writer.await_ready healthy_writer);
             Writer.submit healthy_writer (Tx.start_run ~agent_name:"healthy-scope" ())
             |> require_submit
             |> Writer.await
             |> require_ticket))
    in
    (match failed with
     | Error (Writer.Initialization_failed _) -> ()
     | Error error -> fail (Writer.scope_failure_to_string error)
     | Ok () -> fail "missing durability directory closed successfully");
    match healthy with
    | Error error -> fail (Writer.scope_failure_to_string error)
    | Ok healthy_receipt ->
      check
        int
        "sibling scope remains durable"
        1
        (Journal.cursor_seq healthy_receipt.through))
;;

let test_clean_reopen_continues_exact_cursor () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let first_receipt = ref None in
    with_fresh codec dir (fun _sw writer ->
      let receipt =
        require_ticket
          (Writer.await
             (require_submit
                (Writer.submit writer (Tx.start_run ~agent_name:"reopen" ()))))
      in
      first_receipt := Some receipt;
      require_closed (Writer.close_and_await writer));
    let first = Option.get !first_receipt in
    with_existing codec dir (fun _sw writer ->
      let run, _opened = first.value in
      let second =
        require_ticket
          (Writer.await
             (require_submit
                (Writer.submit
                   writer
                   (Tx.open_node
                      ~run
                      ~parent:(Journal.run_root run)
                      ~kind:(Event.Agent_turn { ordinal = 0 })
                      ()))))
      in
      check
        int
        "reopened cursor advances exactly once"
        (Journal.cursor_seq first.through + 1)
        (Journal.cursor_seq second.through);
      let events, through = read_complete_page writer ~after:first.through ~limit:1 in
      check int "one post-reopen event" 1 (List.length events);
      let _node, opened = second.value in
      check
        bool
        "post-reopen identity is exact"
        true
        (Event.equal opened (List.hd events));
      check int "post-reopen replay cursor" 2 (Journal.cursor_seq through);
      require_closed (Writer.close_and_await writer)))
;;

let test_abort_transaction_is_one_durable_terminal_group () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let run, output, setup_through, _events = open_output writer in
      let terminal = Event.Cancelled { reason = Some "scope shutdown"; data = None } in
      let aborted =
        require_ticket
          (Writer.await
             (require_submit (Writer.submit writer (Tx.abort_run ~run terminal))))
      in
      check int "entire open subtree closes together" 4 aborted.group_event_count;
      let events, through = read_complete_page writer ~after:setup_through ~limit:4 in
      check
        bool
        "abort receipt is exact durable tail"
        true
        (List.equal Event.equal aborted.value events);
      check int "terminal watermark" 8 (Journal.cursor_seq through);
      let rejected = require_submit (Writer.submit writer (delta_transaction output 1)) in
      (match Writer.await rejected with
       | Error
           (Writer.Transaction_rejected
              (Journal.Invariant_violation (Journal.Node_already_closed node_id))) ->
         check bool "exact closed node" true (Event.Node_id.equal node_id output)
       | Error error -> fail (Writer.ticket_error_to_string error)
       | Ok _ -> fail "closed output accepted another delta");
      require_closed (Writer.close_and_await writer)))
;;

let test_repeated_unknown_waits_for_typed_external_wake () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let blocker = Eio.Path.(dir / "events.v1.commit") in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
    let durable_event = ref None in
    let durable_through = ref None in
    with_fresh codec dir (fun _sw writer ->
      let first =
        require_submit
          (Writer.submit writer (Tx.start_run ~agent_name:"unknown-create" ()))
      in
      let waiting = await_reconciliation_wait writer ~outcome_count:2 in
      check int "repeated unknown does not self-wake" 0 waiting.reconciliation_wakes;
      check
        bool
        "no wake source before an external event"
        true
        (Option.is_none waiting.last_reconciliation_wake);
      let second =
        require_submit
          (Writer.submit writer (Tx.start_run ~agent_name:"queued-during-wait" ()))
      in
      Eio.Fiber.yield ();
      let after_submit = Writer.stats writer in
      check
        int
        "submission does not retry filesystem"
        2
        after_submit.reconciliation_unknowns;
      check int "submission is not a durability wake" 0 after_submit.reconciliation_wakes;
      Eio.Path.rmtree ~missing_ok:false blocker;
      check
        bool
        "unknown outcome accepts typed wake"
        true
        (Writer.wake_reconciliation writer ~source:Writer.Durability_health_changed);
      check
        bool
        "a claimed wake cannot be claimed again"
        false
        (Writer.wake_reconciliation writer ~source:Writer.Operator_requested);
      let receipt = require_ticket (Writer.await first) in
      let _run, opened = receipt.value in
      durable_event := Some opened;
      durable_through := Some receipt.through;
      (match Writer.await second with
       | Error
           (Writer.Transaction_rejected
              (Journal.Invariant_violation Journal.Top_level_run_already_exists)) -> ()
       | Error error -> fail (Writer.ticket_error_to_string error)
       | Ok _ -> fail "second top-level run was accepted");
      check int "reconciled command commits once" 1 (Journal.cursor_seq receipt.through);
      check int "reconciled command is one durability group" 1 receipt.group_event_count;
      let observed = Writer.stats writer in
      check int "both unknown outcomes are observed" 2 observed.reconciliation_unknowns;
      check int "reconciliation wake is observed" 1 observed.reconciliation_wakes;
      check
        bool
        "typed wake source is retained"
        true
        (observed.last_reconciliation_wake
         = Some (Writer.External_wake Writer.Durability_health_changed));
      check
        bool
        "successful reconciliation clears current evidence"
        true
        (Option.is_none observed.current_reconciliation);
      require_closed (Writer.close_and_await writer));
    let through = Option.get !durable_through in
    with_existing codec dir (fun _sw writer ->
      require_scope (Writer.await_ready writer);
      let page =
        match
          Writer.read_page writer ~after:(cursor_at through 0) ~through ~limit:1 ()
        with
        | Ok page -> page
        | Error error -> fail (Writer.read_error_to_string error)
      in
      check
        bool
        "reopen preserves the exact reconciled event"
        true
        (List.equal Event.equal [ Option.get !durable_event ] page.events);
      check_cursor "reopen preserves the reconciled cursor" through page.next_cursor))
;;

let test_close_terminates_unresolved_reconciliation () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let blocker = Eio.Path.(dir / "events.v1.commit") in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
    let writer_ref = ref None in
    let first_waiter = ref None in
    let second_waiter = ref None in
    let outcome =
      Writer.run ~codec ~dir (fun ~sw writer ->
        writer_ref := Some writer;
        let first =
          require_submit
            (Writer.submit writer (Tx.start_run ~agent_name:"close-unknown-1" ()))
        in
        let second =
          require_submit
            (Writer.submit writer (Tx.start_run ~agent_name:"close-unknown-2" ()))
        in
        ignore (await_reconciliation_wait writer ~outcome_count:2);
        Eio.Fiber.fork ~sw (fun () -> first_waiter := Some (Writer.await first));
        Eio.Fiber.fork ~sw (fun () -> second_waiter := Some (Writer.await second)))
    in
    (match outcome with
     | Error (Writer.Reconciliation_unresolved_on_close { evidence }) ->
       check int "close performs one final exact reconciliation" 3 evidence.outcome_count
     | Error error -> fail (Writer.scope_failure_to_string error)
     | Ok () -> fail "unresolved reconciliation closed successfully");
    let check_waiter = function
      | Error
          (Writer.Scope_failed (Writer.Reconciliation_unresolved_on_close { evidence }))
        -> check int "ticket retains close evidence" 3 evidence.outcome_count
      | Error error -> fail (Writer.ticket_error_to_string error)
      | Ok _ -> fail "ambiguous ticket reported durable success"
    in
    check_waiter (Option.get !first_waiter);
    check_waiter (Option.get !second_waiter);
    let observed = Writer.stats (Option.get !writer_ref) in
    check int "close wake is observed" 1 observed.reconciliation_wakes;
    check
      bool
      "close wake source is typed"
      true
      (observed.last_reconciliation_wake = Some Writer.Close_requested);
    check int "all ambiguous tickets settle" observed.accepted observed.settled;
    check int "failed close clears queue" 0 observed.queue_depth;
    check int "failed close clears in-flight" 0 observed.in_flight_commands;
    Eio.Path.rmtree ~missing_ok:false blocker;
    require_scope
      (Writer.resume ~codec ~dir (fun ~sw:_ writer ->
         require_scope (Writer.await_ready writer);
         match Writer.current_cursor writer with
         | Ok cursor ->
           check int "unresolved close publishes no events" 0 (Journal.cursor_seq cursor)
         | Error error -> fail (Writer.read_error_to_string error))))
;;

let test_each_external_wake_authorizes_one_reconciliation () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let blocker = Eio.Path.(dir / "events.v1.commit") in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
    let ticket_ref = ref None in
    let outcome =
      Writer.run ~codec ~dir (fun ~sw:_ writer ->
        let ticket =
          require_submit
            (Writer.submit writer (Tx.start_run ~agent_name:"operator-wake" ()))
        in
        ticket_ref := Some ticket;
        ignore (await_reconciliation_wait writer ~outcome_count:2);
        check
          bool
          "operator wake is accepted"
          true
          (Writer.wake_reconciliation writer ~source:Writer.Operator_requested);
        let waiting = await_reconciliation_wait writer ~outcome_count:3 in
        check int "one external wake causes one retry" 1 waiting.reconciliation_wakes;
        check
          bool
          "operator wake source is retained"
          true
          (waiting.last_reconciliation_wake
           = Some (Writer.External_wake Writer.Operator_requested));
        Eio.Fiber.yield ();
        let stable = Writer.stats writer in
        check
          int
          "no autonomous retry follows the external attempt"
          3
          stable.reconciliation_unknowns)
    in
    (match outcome with
     | Error (Writer.Reconciliation_unresolved_on_close { evidence }) ->
       check int "close owns the next and final retry" 4 evidence.outcome_count
     | Error error -> fail (Writer.scope_failure_to_string error)
     | Ok () -> fail "blocked reconciliation closed successfully");
    match Writer.await (Option.get !ticket_ref) with
    | Error (Writer.Scope_failed (Writer.Reconciliation_unresolved_on_close _)) -> ()
    | Error error -> fail (Writer.ticket_error_to_string error)
    | Ok _ -> fail "blocked ticket reported durable success")
;;

let test_owned_supervisor_drains_same_scope_waiter () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let writer = ref None in
    let ticket = ref None in
    let waiter = ref None in
    require_scope
      (Writer.run ~codec ~dir (fun ~sw created ->
         writer := Some created;
         let accepted =
           require_submit
             (Writer.submit created (Tx.start_run ~agent_name:"owned-scope" ()))
         in
         ticket := Some accepted;
         Eio.Fiber.fork ~sw (fun () -> waiter := Some (Writer.await accepted))));
    let receipt = require_ticket (Option.get !waiter) in
    check
      int
      "owned supervisor drains accepted ticket"
      1
      (Journal.cursor_seq receipt.through);
    require_closed (Writer.await_closed (Option.get !writer));
    let observed = Writer.stats (Option.get !writer) in
    check
      int
      "owned supervisor settles accepted ticket"
      observed.accepted
      observed.settled;
    check int "owned supervisor clears queue" 0 observed.queue_depth;
    check int "owned supervisor clears in-flight" 0 observed.in_flight_commands;
    ignore (require_ticket (Writer.await (Option.get !ticket))))
;;

let test_callback_exception_preserves_durable_group_truth () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let writer_ref = ref None in
    let setup_through_ref = ref None in
    let first_receipt = ref None in
    let second_ticket = ref None in
    (match
       with_fresh codec dir (fun _sw writer ->
         writer_ref := Some writer;
         let _run, output, setup_through, _events = open_output writer in
         setup_through_ref := Some setup_through;
         let first = require_submit (Writer.submit writer (delta_transaction output 1)) in
         let second =
           require_submit (Writer.submit writer (delta_transaction output 2))
         in
         second_ticket := Some second;
         first_receipt := Some (require_ticket (Writer.await first));
         (match Writer.ticket_phase second with
          | Writer.Committing -> ()
          | Writer.Queued | Writer.Reconciling | Writer.Settled ->
            fail "second ticket was not pending inside durable settlement");
         raise Callback_failed)
     with
     | () -> fail "callback failure returned normally"
     | exception Callback_failed -> ()
     | exception exn -> raise exn);
    let first = Option.get !first_receipt in
    let second = require_ticket (Writer.await (Option.get !second_ticket)) in
    check_cursor
      "callback failure keeps one durable group cursor"
      first.through
      second.through;
    check int "callback failure keeps exact durable group size" 2 first.group_event_count;
    check int "callback failure keeps sibling group size" 2 second.group_event_count;
    require_closed (Writer.await_closed (Option.get !writer_ref));
    let observed = Writer.stats (Option.get !writer_ref) in
    check
      int
      "callback failure settles every accepted ticket"
      observed.accepted
      observed.settled;
    check int "callback failure clears queue" 0 observed.queue_depth;
    check int "callback failure clears in-flight" 0 observed.in_flight_commands;
    with_existing codec dir (fun _sw writer ->
      require_scope (Writer.await_ready writer);
      let page =
        match
          Writer.read_page
            writer
            ~after:(Option.get !setup_through_ref)
            ~through:first.through
            ~limit:2
            ()
        with
        | Ok page -> page
        | Error error -> fail (Writer.read_error_to_string error)
      in
      check
        bool
        "callback failure replays both durable events"
        true
        (List.equal Event.equal [ first.value; second.value ] page.events)))
;;

let test_callback_exception_retains_unresolved_scope_failure () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let blocker = Eio.Path.(dir / "events.v1.commit") in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
    let ticket_ref = ref None in
    (match
       Writer.run ~codec ~dir (fun ~sw:_ writer ->
         let ticket =
           require_submit
             (Writer.submit writer (Tx.start_run ~agent_name:"callback-unknown" ()))
         in
         ticket_ref := Some ticket;
         let _observed = await_reconciliation_wait writer ~outcome_count:2 in
         raise Callback_failed)
     with
     | exception
         Writer.Callback_failed_after_scope_failure
           (Callback_failed, Writer.Reconciliation_unresolved_on_close { evidence }) ->
       check int "callback and close retain exact evidence" 3 evidence.outcome_count
     | exception exn -> raise exn
     | Ok _ | Error _ -> fail "callback failure returned as a normal scope result");
    match Writer.await (Option.get !ticket_ref) with
    | Error (Writer.Scope_failed (Writer.Reconciliation_unresolved_on_close { evidence }))
      -> check int "ticket retains the same close evidence" 3 evidence.outcome_count
    | Error error -> fail (Writer.ticket_error_to_string error)
    | Ok _ -> fail "ambiguous ticket reported durable success")
;;

let test_reserved_callback_exception_survives_unresolved_scope_failure () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let blocker = Eio.Path.(dir / "events.v1.commit") in
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 blocker;
    match
      Writer.run ~codec ~dir (fun ~sw:_ writer ->
        let ticket =
          require_submit
            (Writer.submit writer (Tx.start_run ~agent_name:"reserved-callback" ()))
        in
        ignore ticket;
        ignore (await_reconciliation_wait writer ~outcome_count:2);
        raise (Eio.Cancel.Cancelled Exit))
    with
    | exception Eio.Cancel.Cancelled Exit -> ()
    | exception Writer.Callback_failed_after_scope_failure _ ->
      fail "scope shutdown failure masked the reserved callback exception"
    | exception exn -> raise exn
    | Ok _ | Error _ -> fail "reserved callback exception returned normally")
;;

let test_durable_success_settles_group_before_supervisor_cancellation () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    let writer_ref = ref None in
    let output_ref = ref None in
    let setup_through_ref = ref None in
    let first_ticket = ref None in
    let second_ticket = ref None in
    let first_receipt = ref None in
    (match
       with_fresh codec dir (fun sw writer ->
         writer_ref := Some writer;
         let _run, output, setup_through, _events = open_output writer in
         output_ref := Some output;
         setup_through_ref := Some setup_through;
         let first = require_submit (Writer.submit writer (delta_transaction output 1)) in
         let second =
           require_submit (Writer.submit writer (delta_transaction output 2))
         in
         first_ticket := Some first;
         second_ticket := Some second;
         first_receipt := Some (require_ticket (Writer.await first));
         (match Writer.ticket_phase second with
          | Writer.Committing -> ()
          | Writer.Queued | Writer.Reconciling | Writer.Settled ->
            fail "second ticket was not pending inside durable settlement");
         Eio.Switch.fail sw Cancel_scope)
     with
     | () -> fail "failed supervisor switch returned normally"
     | exception Cancel_scope -> ()
     | exception exn -> raise exn);
    let first = Option.get !first_receipt in
    let second = require_ticket (Writer.await (Option.get !second_ticket)) in
    check
      int
      "same durable group cursor"
      (Journal.cursor_seq first.through)
      (Journal.cursor_seq second.through);
    check int "same durable group size" first.group_event_count second.group_event_count;
    check int "both commands committed together" 2 first.group_event_count;
    (match Writer.await_closed (Option.get !writer_ref) with
     | Error (Writer.Supervisor_cancelled Cancel_scope) -> ()
     | Error error -> fail (Writer.scope_failure_to_string error)
     | Ok () -> fail "cancelled supervisor reported a normal actor close");
    let observed = Writer.stats (Option.get !writer_ref) in
    check
      int
      "cancelled scope settles every accepted ticket"
      observed.accepted
      observed.settled;
    check int "cancelled scope clears queue" 0 observed.queue_depth;
    check int "cancelled scope clears in-flight" 0 observed.in_flight_commands;
    with_existing codec dir (fun _sw writer ->
      let output = Option.get !output_ref in
      ignore (submit_and_await writer (delta_transaction output 3));
      let page =
        match
          Writer.read_page
            writer
            ~after:(Option.get !setup_through_ref)
            ~through:first.through
            ~limit:2
            ()
        with
        | Ok page -> page
        | Error error -> fail (Writer.read_error_to_string error)
      in
      check
        bool
        "reopen replays the exact successful group"
        true
        (List.equal Event.equal [ first.value; second.value ] page.events);
      require_closed (Writer.close_and_await writer)))
;;

let test_frozen_pages_remain_lossless_after_close () =
  Eio_main.run
  @@ fun env ->
  with_temp_dir env (fun codec dir ->
    make_dir dir;
    with_fresh codec dir (fun _sw writer ->
      let _run, output, setup_through, _events = open_output writer in
      let first = require_submit (Writer.submit writer (delta_transaction output 1)) in
      let second = require_submit (Writer.submit writer (delta_transaction output 2)) in
      let first_receipt = require_ticket (Writer.await first) in
      let second_receipt = require_ticket (Writer.await second) in
      let first_page =
        match Writer.read_page writer ~after:setup_through ~limit:1 () with
        | Ok page -> page
        | Error error -> fail (Writer.read_error_to_string error)
      in
      check bool "first frozen page has a remainder" true first_page.has_more;
      check_cursor
        "first page freezes the exact current watermark"
        second_receipt.through
        first_page.high_watermark;
      check_cursor
        "first page advances by the exact first event"
        (cursor_at setup_through (Journal.cursor_seq setup_through + 1))
        first_page.next_cursor;
      let third = submit_and_await writer (delta_transaction output 3) in
      require_closed (Writer.close_and_await writer);
      let frozen_tail =
        match
          Writer.read_page
            writer
            ~after:first_page.next_cursor
            ~through:first_page.high_watermark
            ~limit:1
            ()
        with
        | Ok page -> page
        | Error error -> fail (Writer.read_error_to_string error)
      in
      check
        bool
        "frozen tail excludes later append"
        true
        (List.equal Event.equal [ second_receipt.value ] frozen_tail.events);
      check bool "frozen tail is complete" false frozen_tail.has_more;
      check
        int
        "frozen tail keeps old watermark"
        (Journal.cursor_seq second_receipt.through)
        (Journal.cursor_seq frozen_tail.high_watermark);
      check_cursor
        "frozen tail keeps exact old watermark scope"
        second_receipt.through
        frozen_tail.high_watermark;
      check
        int
        "frozen tail stops at old watermark"
        (Journal.cursor_seq second_receipt.through)
        (Journal.cursor_seq frozen_tail.next_cursor);
      check_cursor
        "frozen tail stops at exact old watermark"
        second_receipt.through
        frozen_tail.next_cursor;
      let later =
        match Writer.read_page writer ~after:first_page.high_watermark ~limit:1 () with
        | Ok page -> page
        | Error error -> fail (Writer.read_error_to_string error)
      in
      check
        bool
        "new watermark retains later append"
        true
        (List.equal Event.equal [ third.value ] later.events);
      check bool "later page is complete" false later.has_more;
      check
        int
        "later page exposes new watermark"
        (Journal.cursor_seq third.through)
        (Journal.cursor_seq later.high_watermark);
      check_cursor
        "later page exposes exact new watermark"
        third.through
        later.high_watermark;
      check
        int
        "later page reaches new watermark"
        (Journal.cursor_seq third.through)
        (Journal.cursor_seq later.next_cursor);
      check_cursor
        "later page reaches exact new watermark"
        third.through
        later.next_cursor;
      check
        bool
        "first receipt remains exact"
        true
        (Event.equal first_receipt.value (List.hd first_page.events))))
;;

let () =
  run
    "execution lane writer"
    [ ( "durability"
      , [ test_case
            "single command commits and close drains"
            `Quick
            test_single_command_commits_and_close_drains
        ; test_case
            "ready set is one FIFO durable group"
            `Quick
            test_ready_set_is_one_fifo_durable_group
        ; test_case
            "semantic rejection does not poison ready group"
            `Quick
            test_semantic_rejection_does_not_poison_ready_group
        ; test_case
            "effect attempt and settlement survive restart"
            `Quick
            test_effect_attempt_and_settlement_survive_restart
        ; test_case
            "structural occurrence identity is parent local"
            `Quick
            test_structural_occurrence_identity_is_parent_local
        ; test_case
            "Agent scope owns effect topology"
            `Quick
            test_agent_scope_owns_effect_topology
        ; test_case
            "Agent scope executes pending command after restart"
            `Quick
            test_agent_scope_executes_pending_after_restart
        ; test_case
            "concurrent submit and close linearize without loss"
            `Quick
            test_concurrent_submit_and_close_linearize_without_loss
        ; test_case
            "cancelled waiter does not cancel ticket"
            `Quick
            test_cancelled_waiter_does_not_cancel_ticket
        ; test_case
            "supervisor cancellation settles accepted ticket"
            `Quick
            test_supervisor_cancellation_settles_accepted_ticket
        ; test_case
            "initialization failure is scope local"
            `Quick
            test_initialization_failure_is_scope_local
        ; test_case
            "clean reopen continues exact cursor"
            `Quick
            test_clean_reopen_continues_exact_cursor
        ; test_case
            "abort transaction is one durable terminal group"
            `Quick
            test_abort_transaction_is_one_durable_terminal_group
        ; test_case
            "repeated unknown waits for typed external wake"
            `Quick
            test_repeated_unknown_waits_for_typed_external_wake
        ; test_case
            "close terminates unresolved reconciliation"
            `Quick
            test_close_terminates_unresolved_reconciliation
        ; test_case
            "each external wake authorizes one reconciliation"
            `Quick
            test_each_external_wake_authorizes_one_reconciliation
        ; test_case
            "owned supervisor drains same-scope waiter"
            `Quick
            test_owned_supervisor_drains_same_scope_waiter
        ; test_case
            "callback exception preserves durable group truth"
            `Quick
            test_callback_exception_preserves_durable_group_truth
        ; test_case
            "callback exception retains unresolved scope failure"
            `Quick
            test_callback_exception_retains_unresolved_scope_failure
        ; test_case
            "reserved callback survives unresolved scope failure"
            `Quick
            test_reserved_callback_exception_survives_unresolved_scope_failure
        ; test_case
            "durable success settles group before supervisor cancellation"
            `Quick
            test_durable_success_settles_group_before_supervisor_cancellation
        ; test_case
            "frozen pages remain lossless after close"
            `Quick
            test_frozen_pages_remain_lossless_after_close
        ] )
    ]
;;
