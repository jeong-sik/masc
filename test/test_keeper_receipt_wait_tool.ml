(** The [keeper_receipt_wait] tool.

    A call checks the request and answers with the wait the turn ends on. It
    records nothing: the wait joins the execution record with the turn's
    checkpoint. These cases run the handler against real request records and
    a real outbox, and run the tool through the bundle a Keeper turn builds, so
    the terminal state the turn reads is the one the tool left. *)

open Alcotest
open Masc

module Outbox = Keeper_client_tool_outbox
module Background = Keeper_execute_background.For_testing

let () = Mirage_crypto_rng_unix.use_default ()
let keeper_name = "wait-tool-keeper"

let meta () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String keeper_name
        ; "trace_id", `String "trace-wait-tool"
        ; "activation_mode", `String "manual"
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
;;

let get = function Ok value -> value | Error detail -> fail detail

(* The producer context a background Execute run keeps in its request record. *)
let execute_context =
  [ "execute_background", `Assoc [ "arguments", `Assoc [ "command", `String "sleep 30" ] ] ]
;;

let with_workspace f =
  let base_path = Filename.temp_file "masc_receipt_wait_tool_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o700;
  let base_path = try Unix.realpath base_path with Unix.Unix_error _ -> base_path in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Filename.quote_command "rm" [ "-rf"; base_path ])))
    (fun () ->
       Eio_main.run (fun env ->
         Eio.Switch.run (fun sw ->
           Masc_test_deps.init_eio_clock ~sw env;
           Fs_compat.set_fs (Eio.Stdenv.fs env);
           let config = Workspace.default_config base_path in
           ignore (Workspace.init config ~agent_name:(Some keeper_name));
           f ~sw ~clock:(Eio.Stdenv.clock env) config)))
;;

let submit ~sw ~base_path ?request_context f =
  match
    Keeper_msg_async.submit_with_request_id
      ?request_context
      ~background_sw:sw
      ~base_path
      ~caller:keeper_name
      ~f
      ~keeper_name
      ()
  with
  | Ok { acceptance = Keeper_msg_async.Durably_accepted; request_id } -> request_id
  | Ok outcome ->
    fail (Yojson.Safe.to_string (Keeper_msg_async.submit_outcome_to_json outcome))
  | Error error ->
    fail (Yojson.Safe.to_string (Keeper_msg_async.submit_error_to_json error))
;;

let wait_until_ended ~clock ~base_path request_id =
  Eio.Time.with_timeout_exn clock 15. (fun () ->
    let rec loop () =
      match
        Keeper_msg_async.load_canonical_request ~base_path ~caller:keeper_name request_id
      with
      | Keeper_msg_async.Found entry
        when not (Keeper_receipt_wait_resolution.request_may_have_worker entry) -> ()
      | Keeper_msg_async.Found _ | Keeper_msg_async.Absent
      | Keeper_msg_async.Unreadable _ | Keeper_msg_async.Rejected _ ->
        Eio.Time.sleep clock 0.01;
        loop ()
    in
    loop ())
;;

let args request_id = `Assoc [ "request_id", `String request_id ]

let call config args =
  Keeper_tool_receipt_wait.handle ~config ~meta:(meta ()) ~args
;;

let refusal_class (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Failed class_ -> class_
  | Tool_result.Completed () | Tool_result.Deferred () ->
    fail "expected a refusal, got a result that went through"
;;

let expect_refused ~class_ label execution =
  check bool label true (refusal_class execution = class_);
  check bool (label ^ " has no receipt") true
    (Option.is_none execution.Keeper_tool_execution.terminal_effect_receipt)
;;

let expect_wait ~request_id label (execution : Keeper_tool_execution.t) =
  (match execution.disposition with
   | Tool_result.Completed () -> ()
   | Tool_result.Deferred () | Tool_result.Failed _ -> fail (label ^ ": the call did not complete"));
  match execution.terminal_effect_receipt with
  | Some (Keeper_tool_execution.Receipt_wait_requested { request_id = waited }) ->
    check string (label ^ " names the request") request_id waited
  | Some (Keeper_tool_execution.Surface_post_completed _) | None ->
    fail (label ^ ": the result carries no wait")
;;

let test_arguments_are_exact () =
  with_workspace (fun ~sw:_ ~clock:_ config ->
    List.iter
      (fun (label, input) ->
         expect_refused ~class_:Tool_result.Policy_rejection label (call config input))
      [ "no request_id", `Assoc []
      ; "empty request_id", args ""
      ; "request_id is not a string", `Assoc [ "request_id", `Int 1 ]
      ; ( "an extra field"
        , `Assoc [ "request_id", `String "kmsg-a"; "timeout", `Int 5 ] )
      ; "not an object", `String "kmsg-a"
      ])
;;

let test_unknown_request_is_refused () =
  with_workspace (fun ~sw:_ ~clock:_ config ->
    expect_refused
      ~class_:Tool_result.Workflow_rejection
      "no record for the request"
      (call config (args "kmsg-never-submitted")))
;;

let test_request_of_another_producer_is_refused () =
  with_workspace (fun ~sw ~clock config ->
    let base_path = config.Workspace.base_path in
    let request_id =
      submit ~sw ~base_path (fun ~request_id:_ _ -> Keeper_types_profile.tool_result_ok "done")
    in
    wait_until_ended ~clock ~base_path request_id;
    expect_refused
      ~class_:Tool_result.Workflow_rejection
      "a request that is not a background Execute run"
      (call config (args request_id)))
;;

let test_running_run_is_waited_for () =
  with_workspace (fun ~sw ~clock:_ config ->
    let base_path = config.Workspace.base_path in
    let release, resolve_release = Eio.Promise.create () in
    let request_id =
      submit ~sw ~base_path ~request_context:execute_context (fun ~request_id:_ _ ->
        Eio.Promise.await release;
        Keeper_types_profile.tool_result_ok "done")
    in
    expect_wait ~request_id "a run that is still working" (call config (args request_id));
    Eio.Promise.resolve resolve_release ())
;;

(* The worker writes a run's receipt before it settles the request. A request
   that has ended with no receipt in the outbox had its receipt delivered and
   acknowledged already, so there is nothing to wait for. *)
let test_ended_run_is_waited_for_only_while_its_receipt_is_there () =
  with_workspace (fun ~sw ~clock config ->
    let base_path = config.Workspace.base_path in
    let request_id =
      submit ~sw ~base_path ~request_context:execute_context (fun ~request_id:_ _ ->
        Keeper_types_profile.tool_result_ok "done")
    in
    wait_until_ended ~clock ~base_path request_id;
    expect_refused
      ~class_:Tool_result.Workflow_rejection
      "an ended run with no receipt"
      (call config (args request_id));
    get
      (Outbox.retain
         ~base_path
         ~keeper_name
         (Background.receipt_of_unfinished
            ~request_id
            ~arguments:(`Assoc [])
            ~cause:Background.restart_cause));
    expect_wait ~request_id "an ended run whose receipt is waiting" (call config (args request_id)))
;;

(* The tool runs through the bundle a turn builds. The call leaves the wait in
   the terminal state the turn reads, and a refused call leaves it open. *)
let bundle_for config =
  Keeper_tools_agent_core_bundle.For_testing.make_tool_bundle
    ~config
    ~meta:(meta ())
    ~publication_recovery:
      { Keeper_publication_recovery_availability.provider =
          Keeper_publication_recovery_availability.non_runtime_provider
      ; keeper_name
      }
    ~ctx_snapshot:
      (Keeper_context_runtime.create ~eio:false ~system_prompt:"receipt wait fixture")
    ()
;;

let invoke (tool : Agent_core.Tool.t) input =
  let invocation =
    Agent_core.Tool_contract.Invocation.create
      ~tool_use_id:"toolu-receipt-wait"
      ~turn:0
      ~schedule:
        { planned_index = 0
        ; batch_index = 0
        ; batch_size = 1
        ; execution_mode = Agent_core.Tool_contract.Serial
        }
      ~completion:(Agent_core.Tool.completion tool)
  in
  Agent_core.Tool.execute ~invocation tool input
;;

let wait_tool (bundle : Keeper_tools_agent_core.tool_bundle) =
  match
    List.find_opt
      (fun (tool : Agent_core.Tool.t) -> String.equal tool.schema.name "keeper_receipt_wait")
      bundle.agent_core_tools
  with
  | Some tool -> tool
  | None -> fail "the bundle does not offer keeper_receipt_wait"
;;

let test_bundle_keeps_the_wait_in_the_terminal_state () =
  with_workspace (fun ~sw ~clock:_ config ->
    let base_path = config.Workspace.base_path in
    let release, resolve_release = Eio.Promise.create () in
    let request_id =
      submit ~sw ~base_path ~request_context:execute_context (fun ~request_id:_ _ ->
        Eio.Promise.await release;
        Keeper_types_profile.tool_result_ok "done")
    in
    let bundle = bundle_for config in
    Fun.protect ~finally:bundle.cleanup (fun () ->
      let tool = wait_tool bundle in
      (match invoke tool (args "kmsg-never-submitted") with
       | Ok _ | Error _ -> ());
      (match bundle.terminal_effect_state () with
       | Keeper_tools_agent_core.Terminal_effect_open -> ()
       | Keeper_tools_agent_core.Deferred_tool_result
       | Keeper_tools_agent_core.External_effect_deferred
       | Keeper_tools_agent_core.Terminal_effect_completed _
       | Keeper_tools_agent_core.Terminal_effect_failed _ ->
         fail "a refused wait changed the terminal state");
      (match invoke tool (args request_id) with
       | Ok _ -> ()
       | Error error -> fail error.Agent_core.Types.message);
      (match bundle.terminal_effect_state () with
       | Keeper_tools_agent_core.Terminal_effect_completed
           (Keeper_tool_execution.Receipt_wait_requested { request_id = waited }) ->
         check string "the terminal state names the request" request_id waited
       | Keeper_tools_agent_core.Terminal_effect_open
       | Keeper_tools_agent_core.Deferred_tool_result
       | Keeper_tools_agent_core.External_effect_deferred
       | Keeper_tools_agent_core.Terminal_effect_completed
           (Keeper_tool_execution.Surface_post_completed _)
       | Keeper_tools_agent_core.Terminal_effect_failed _ ->
         fail "the completed wait is not in the terminal state"));
    Eio.Promise.resolve resolve_release ())
;;

(* The wait ends a chat execution's turn on a retained checkpoint. A run that
   serves no chat execution has none, so the tool is not on its surface. *)
let names_of descriptors =
  List.map (fun (descriptor : Keeper_tool_descriptor.t) -> descriptor.internal_name) descriptors
;;

let test_a_run_without_a_chat_execution_is_not_offered_the_wait () =
  let all = Keeper_tool_descriptor.all_descriptors () in
  check bool "the wait tool is registered" true
    (List.mem "keeper_receipt_wait" (names_of all));
  let without = Keeper_run_tools_setup.descriptors_for_run ~repetition_execution:None all in
  check bool "a run that serves no chat execution does not get it" false
    (List.mem "keeper_receipt_wait" (names_of without));
  check int "and loses nothing else" (List.length all - 1) (List.length without);
  let serving = Keeper_run_tools_setup.descriptors_for_run ~repetition_execution:(Some ()) all in
  check bool "a run that serves one gets it" true
    (List.mem "keeper_receipt_wait" (names_of serving));
  check int "with every other tool" (List.length all) (List.length serving)
;;

let () =
  run
    "keeper receipt wait tool"
    [ ( "check"
      , [ test_case "arguments are exact" `Quick test_arguments_are_exact
        ; test_case "an unknown request is refused" `Quick test_unknown_request_is_refused
        ; test_case "a request of another producer is refused" `Quick
            test_request_of_another_producer_is_refused
        ; test_case "a run that is still working is waited for" `Quick
            test_running_run_is_waited_for
        ; test_case "an ended run is waited for only while its receipt is there" `Quick
            test_ended_run_is_waited_for_only_while_its_receipt_is_there
        ] )
    ; ( "bundle"
      , [ test_case "the wait stays in the terminal state" `Quick
            test_bundle_keeps_the_wait_in_the_terminal_state
        ] )
    ; ( "surface"
      , [ test_case "a run without a chat execution is not offered the wait" `Quick
            test_a_run_without_a_chat_execution_is_not_offered_the_wait
        ] )
    ]
;;
