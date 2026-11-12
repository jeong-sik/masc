open Alcotest

module Input = Server_observation_input
module Sse = Masc.Sse
module Dataset = Masc.Workspace_dataset_event
module Goals = Masc.Goal_projection_broadcast
module Schedules = Masc.Schedule_invalidation_event
module Slices = Masc.Dashboard_event_slices
module Telemetry = Dashboard_agent_core_bridge

let root = "/tmp/masc-observation-input"
let authority = Sse.runtime_authority_exn ~base_path:root

let event payload : Sse.external_event =
  { ext_payload = payload; ext_frame = ""; ext_event_id = 1; ext_emitted_at = 1.0 }
;;

let test_exact_input_identities () =
  let wire kind fields = event (`Assoc (("type", `String kind) :: fields)) in
  check bool "exact operation identity is retained" true
    (Input.of_event (wire "keeper_chat_operation_event"
      [ "name", `String "piano"; "operation_id", `String "original-operation"
      ; "ts_unix", `Float 1.0 ])
     = Some (Input.Chat_operation { keeper = "piano"; operation_id = "original-operation" }));
  List.iter (fun fields ->
    check bool "invalid operation input is ignored" true
      (Option.is_none (Input.of_event (wire "keeper_chat_operation_event" fields))))
    [ ["name", `String "piano"; "operation_id", `String " "; "ts_unix", `Float 1.0]
    ; ["name", `String "piano"; "operation_id", `String "original-operation"; "ts_unix", `Float nan]
    ; ["name", `String "piano"; "name", `String "other"; "operation_id", `String "original-operation"; "ts_unix", `Float 1.0] ];
  check bool "closed lifecycle phases are decoded" true
    (Input.of_event (wire "keeper_phase_changed"
      ["name", `String "piano";
       "prev_phase", `String (Keeper_state_machine.phase_to_string Keeper_state_machine.Running);
       "new_phase", `String (Keeper_state_machine.phase_to_string Keeper_state_machine.Paused); "ts_unix", `Float 1.0])
     = Some (Input.Keeper { keeper = "piano";
         change = Input.Phase { previous = Running; current = Paused } }));
  check bool "unknown lifecycle phase does not admit input" true
    (Option.is_none (Input.of_event (wire "keeper_phase_changed"
      ["name", `String "piano"; "prev_phase", `String "future";
       "new_phase", `String (Keeper_state_machine.phase_to_string Keeper_state_machine.Paused); "ts_unix", `Float 1.0])))
;;

let test_outputs_are_not_inputs () =
  let outputs =
    [ `Assoc ["type", `String "execution_snapshot"; "execution_invalidated", `Bool false]
    ; `Assoc ["type", `String "operator_snapshot"]
    ; `Assoc ["type", `String "operator_digest"]
    ; `Assoc ["type", `String "project_snapshot"]
    ; `Assoc ["type", `String "transport_health_snapshot"]
    ; `Assoc ["type", `String Dataset.event_type;
        "dataset", `String "dashboard_observation"; "topic", `String "health";
        "scope", `String "workspace"]
    ] in
  List.iter (fun payload ->
    check bool "a projection cannot wake its own producer" true
      (Option.is_none (Input.of_event (event payload)))) outputs;
  check bool "a real compact invalidation remains an input" true
    (Input.of_event (event (`Assoc
      ["type", `String Slices.execution_snapshot_type;
       "execution_invalidated", `Bool true;
       "execution_publication_epoch", `String "producer-epoch";
       "execution_publication_generation", `Int 7])) = Some Input.Execution_invalidated)
;;

let test_notification_envelopes_are_exact () =
  let decode fields = Input.of_event (event (`Assoc fields)) in
  let board = ["type", `String "board_changed"; "event_type", `String "board.changed"] in
  let envelope method_ params =
    ["jsonrpc", `String "2.0"; "method", `String method_; "params", `Assoc params] in
  check bool "the actual Board notification is unwrapped" true
    (decode (envelope "notifications/board" board) = Some Input.Board);
  List.iter (fun fields ->
    check bool "an unrelated protocol envelope cannot become a Board input" true
      (Option.is_none (decode fields)))
    [ ("id", `Int 1) :: envelope "notifications/board" board
    ; envelope "notifications/unrelated" board
    ; envelope "notifications/board" ["type", `String "keeper_row_changed"; "name", `String "piano"]
    ; envelope "notifications/board" (("type", `String "post_created") :: board)
    ; ["jsonrpc", `String "future"; "method", `String "notifications/board"; "params", `Assoc board]
    ];
  check bool "MCP tool registry notification is a tool input" true
    (decode ["jsonrpc", `String "2.0"; "method", `String "notifications/tools/list_changed"]
      = Some (Input.Store Input.Tools))
;;

let test_message_input_is_typed () =
  let decode request_id mention_delivery = Input.of_event (event (`Assoc
      ["type", `String "workspace_message_delivery_changed";
       "request_id", `String request_id; "mention_delivery", `String mention_delivery])) in
  check bool "the original message identity and exact delivery state survive" true
    (decode "original-request" "accepted" = Some (Input.Workspace_messages {
       request_id = "original-request"; mention_delivery = Masc_domain.Mention_accepted }));
  check bool "unknown delivery states cannot invent a source transition" true
    (Option.is_none (decode "original-request" "future"));
  check bool "an empty request is not an input identity" true
    (Option.is_none (decode " " "accepted"))
;;

let test_agent_heartbeat_reaches_only_its_workspace () =
  Eio_main.run (fun env ->
    let previous_fs = Fs_compat.get_fs_opt () in
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let base_path = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () ->
      Masc_test_deps.cleanup_test_workspace base_path;
      match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
      (fun () ->
        let config = Masc.Workspace.default_config base_path in
        ignore (Masc.Workspace.init config ~agent_name:None);
        let original : Masc_domain.agent = {
          id = None; name = "source-agent"; agent_type = "review";
          status = Masc_domain.Active; capabilities = []; current_task = None;
          session_bound_at = "2026-11-05T00:00:00Z";
          last_seen = "2026-11-05T01:00:00Z"; meta = None } in
        let path = Filename.concat (Masc.Workspace.agents_dir config) "source-agent.json" in
        Workspace_agent_record.write config path ~previous:None original;
        let seen = ref [] and foreign = ref [] in
        Eio.Switch.run (fun sw ->
          Input.subscribe ~sw ~base_path (fun input -> seen := input :: !seen);
          Input.subscribe ~sw ~base_path:(base_path ^ "-other")
            (fun input -> foreign := input :: !foreign);
          Workspace_agent_record.write config path ~previous:(Some original)
            {original with last_seen = "2026-11-05T01:05:00Z"};
          check bool "actual source-dated write reaches the direct consumer" true
            (!seen = [Input.Workspace_agent_signal {agent = original.name}]);
          check int "foreign workspace is not woken" 0 (List.length !foreign));
        Workspace_agent_record.write config path ~previous:(Some original)
          {original with last_seen = "2026-11-05T01:10:00Z"};
        check int "quiet release unsubscribes the source hook" 1 (List.length !seen)))
;;

let test_real_board_writer_to_observation_worker () =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect ~finally:(fun () ->
    Masc.Board_dispatch.reset_for_test ();
    Masc.Board.reset_global_for_test ();
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Masc_test_deps.ensure_rng_initialized ();
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc.Board_dispatch.reset_for_test ();
      Masc.Board.reset_global_for_test ();
      (match Masc.Board_dispatch.init_jsonl ~base_path
        ~recipient_lookup:Masc.Recipient_lookup.none_declared () with
       | Ok () -> ()
       | Error _ -> fail "the isolated Board store could not be initialized");
      (* Use the production callback itself: the writer commits its post,
         Board_dispatch invokes this hook, and its JSON-RPC envelope reaches
         the same publication subscriber the freshness worker owns. *)
      Masc.Board_dispatch.set_board_sse_hook
        Server_bootstrap_loops.For_testing.publish_board_sse_event;
      let changes = Eio.Stream.create 1 and results = Eio.Stream.create 4 in
      let publications = ref 0 in
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Input.subscribe ~sw ~base_path (fun input ->
          if input = Input.Board then (
            incr publications;
            if Eio.Stream.is_empty changes then Eio.Stream.add changes ()));
        Proactive_refresh.start_on_change ~sw ~clock:(Eio.Stdenv.clock env)
          ~changes ~config:(Proactive_refresh.default_config ~label:"Board-source" ~interval_s:60.0)
          ~compute:(fun () -> List.length
            (Masc.Board_dispatch.list_posts ~reader:Masc_board_handlers.Board_access.Operator
              ~sort_by:Masc.Board_dispatch.Recent ~limit:10 ()))
          ~on_result:(Eio.Stream.add results);
        check int "initial subscription reads the empty durable store" 0 (Eio.Stream.take results);
        (match Masc.Board_dispatch.create_post ~author:"observation-source-test"
          ~content:"a committed Board post wakes its observer" ~post_kind:Masc.Board.Human_post
          ~visibility:Masc.Board.Public () with
         | Ok _ -> ()
         | Error failure -> fail (Masc.Board.Post_publication_failure.to_string failure));
        check int "the exact Board producer woke the reader" 1 !publications;
        check int "the event consumer observes the committed post" 1 (Eio.Stream.take results)));
      (* Normal Switch.run return must retire the quiet worker and remove its
         input listener. No outer Fiber.first cancellation can hide a leak. *)
      Server_bootstrap_loops.For_testing.publish_board_sse_event Masc.Board_dispatch.Board_changed;
      check int "normal scope release removed the input subscription" 1 !publications))
;;

let test_real_tools_notification_is_an_input () =
  Eio_main.run (fun _env ->
    let seen = ref [] in
    Eio.Switch.run (fun sw ->
      Input.subscribe ~sw ~base_path:root (fun input -> seen := input :: !seen);
      Masc.Mcp_server_eio_protocol.broadcast_tools_list_changed ();
      check bool "the protocol's actual tool registry publisher reaches the input" true
        (!seen = [Input.Store Input.Tools])))
;;

let test_real_telemetry_sample_is_an_input () =
  Eio_main.run (fun _env ->
    let sample : Telemetry.sample =
      { provider_id = "fixture-private-provider"; model_id = "fixture-private-model"
      ; ttfb_ms = 1.0; total_duration_ms = 2.0; serialization_ms = 0.0
      ; usage_reported = false; input_tokens = None; output_tokens = None
      ; throughput_tokens_per_s = None; cost_usd = None; cache_hit = None
      ; status = Success; retry_count = 0 } in
    let seen = ref [] and published = ref None in
    let remove = Sse.subscribe_publication_inputs ~runtime_authority:authority
        (fun wire -> published := Some wire) in
    Telemetry.clear ();
    Fun.protect ~finally:(fun () -> remove (); Telemetry.clear ()) (fun () ->
      Eio.Switch.run (fun sw ->
        Input.subscribe ~sw ~base_path:root (fun input -> seen := input :: !seen);
        List.iter (fun status -> Telemetry.record { sample with status })
          Telemetry.[Success; Error { transient = true }; Cancelled { reason = "fixture cancellation" }];
        check bool "the actual collector publishes all typed outcomes through its installed SSE hook" true
          (!seen = [Input.Telemetry_sample; Input.Telemetry_sample; Input.Telemetry_sample]);
        let original = match !published with
          | Some wire -> wire
          | None -> fail "the actual sample collector published no event" in
        let malformed = match original.ext_payload with
          | `Assoc fields ->
            let fields = List.map (function
              | "payload", `Assoc entry -> "payload", `Assoc
                  (("recorded_at", `Float nan) :: List.remove_assoc "recorded_at" entry)
              | other -> other) fields in
            { original with ext_payload = `Assoc fields }
          | _ -> fail "the actual collector changed its envelope" in
        check bool "invalid entry identity cannot become a sample input" true
          (Option.is_none (Input.of_event malformed));
        check bool "the absent telemetry_event producer is not accepted" true
          (Option.is_none (Input.of_event (event (`Assoc
            ["type", `String "agent_core:telemetry_event";
             "event_type", `String "telemetry_event"; "ts_unix", `Float 1.0;
             "agent_name", `String "piano"; "payload", `Assoc []])))))))
;;

let test_nonexternal_scope_and_release () =
  Eio_main.run (fun _env ->
    let current = ref [] and foreign = ref [] and external_calls = ref 0 in
    let external_id = "observation-input-external-boundary" in
    Sse.subscribe_external ~runtime_authority:authority ~id:external_id
      ~callback:(fun _ -> incr external_calls) ();
    Fun.protect ~finally:(fun () -> Sse.unsubscribe_external external_id) (fun () ->
      Eio.Switch.run (fun sw ->
        Input.subscribe ~sw ~base_path:root (fun input -> current := input :: !current);
        Input.subscribe ~sw ~base_path:(root ^ "-foreign") (fun input -> foreign := input :: !foreign);
        Goals.changed ~base_path:root;
        check bool "the original non-external Goal publisher reaches the input" true
          (!current = [Input.Store Input.Goals]);
        check int "the other workspace receives no input" 0 (List.length !foreign);
        check int "non-external still bypasses transports" 0 !external_calls;
        Sse.broadcast_to_sse_runtime_observers authority Schedules.json;
        check bool "the Schedule publication uses the same boundary" true
          (!current = [Input.Store Input.Schedule; Input.Store Input.Goals]));
      Goals.changed ~base_path:root;
      check int "switch release unsubscribes only its own listeners" 2 (List.length !current)))
;;

let test_internal_scope_and_presence_bypass () =
  Eio_main.run (fun _env ->
    let seen = ref 0 and old = ref 0 in
    let remove_current = Sse.subscribe_publication_inputs ~runtime_authority:authority
        ~observer_instance_id:"current" (fun _ -> incr seen) in
    let remove_old = Sse.subscribe_publication_inputs ~runtime_authority:authority
        ~observer_instance_id:"old" (fun _ -> incr old) in
    Fun.protect ~finally:(fun () -> remove_current (); remove_old ()) (fun () ->
      let scope = Sse.observer_scope ~runtime_authority:authority ~instance_id:"current" in
      Sse.broadcast_to (Sse.Scoped_runtime_observers scope) (`Assoc ["type", `String "change"]);
      check int "current workspace instance receives its publication" 1 !seen;
      check int "old instance receives none" 0 !old;
      Sse.broadcast_presence_to_runtime authority (`Assoc ["type", `String "change"]);
      check int "presence never calls observation inputs" 1 !seen;
      remove_current (); remove_current ();
      Sse.broadcast_to_sse_runtime_observers authority Goals.(
        `Assoc ["type", `String changed_event]);
      check int "idempotent removal cannot retain the callback" 1 !seen;
      check int "removing one listener preserves another" 1 !old))
;;

let test_listener_failure_cannot_replace_publication () =
  Eio_main.run (fun _env ->
    let received = ref 0 and committed = ref false in
    let remove_bad = Sse.subscribe_publication_inputs ~runtime_authority:authority
        (fun _ -> raise (Eio.Cancel.Cancelled Exit)) in
    let remove_good = Sse.subscribe_publication_inputs ~runtime_authority:authority
        (fun _ -> incr received) in
    Fun.protect ~finally:(fun () -> remove_good (); remove_bad ()) (fun () ->
      Sse.broadcast_to_with_commit (Sse.Runtime_observers authority)
        ~on_committed:(fun _ -> committed := true)
        (`Assoc ["type", `String "input"]);
      check bool "the publication keeps its original receipt" true !committed;
      check int "one failed listener cannot suppress another" 1 !received))
;;

let test_listener_preserves_the_callers_actual_cancellation () =
  Eio_main.run (fun _env ->
    let published = ref false in
    let reason = Failure "cancel publication caller" in
    match Eio.Cancel.sub (fun cancellation ->
      let remove = Sse.subscribe_publication_inputs ~runtime_authority:authority
          (fun _ ->
            Eio.Cancel.cancel cancellation reason;
            raise (Eio.Cancel.Cancelled Exit)) in
      Fun.protect ~finally:remove (fun () ->
        Sse.broadcast_to_sse_runtime_observers authority Goals.(
          `Assoc ["type", `String changed_event]);
        published := true;
        Eio.Fiber.check ())) with
    | () -> fail "the caller's actual cancellation disappeared"
    | exception Eio.Cancel.Cancelled actual when actual == reason ->
        check bool "publication returns before the next cancellation boundary" true !published
    | exception exn -> raise exn)
;;

let test_source_to_change_worker_without_output_feedback () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let changes = Eio.Stream.create 1 in
    let read = Eio.Stream.create 4 in
    let never, _ = Eio.Promise.create () in
    let calls = ref 0 in
    Eio.Fiber.first
      (fun () -> Eio.Switch.run (fun sw ->
        Input.subscribe ~sw ~base_path:root (fun _ ->
          if Eio.Stream.is_empty changes then Eio.Stream.add changes ());
        Proactive_refresh.start_on_change ~sw
          ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~changes
          ~config:(Proactive_refresh.default_config ~label:"source-to-reader" ~interval_s:60.0)
          ~compute:(fun () -> incr calls; !calls)
          ~on_result:(fun count ->
            Sse.broadcast_to_sse_runtime_observers authority
              (`Assoc ["type", `String "operator_snapshot"]);
            Dataset.announce_dashboard_observation ~base_path:root
              ~scope:`Workspace `Health;
            Eio.Stream.add read count);
        Eio.Promise.await never))
      (fun () ->
        check int "subscribed before initial read" 1 (Eio.Stream.take read);
        Eio.Fiber.yield ();
        check bool "healthy output arms no timer" false (Eio_mock.Clock.try_advance clock);
        Goals.changed ~base_path:root;
        check int "non-external committed source wakes the same reader" 2 (Eio.Stream.take read);
        Eio.Fiber.yield ();
        check int "output invalidations never feed the source back" 2 !calls;
        check bool "the consumer settles after the source read" false
          (Eio_mock.Clock.try_advance clock)))
;;

let test_transport_lifecycle_to_worker_without_delivery_feedback () =
  Eio_mock.Backend.run (fun () ->
    let clock = Eio_mock.Clock.make () in
    let changes = Eio.Stream.create 1 and reads = Eio.Stream.create 4 in
    let never, _ = Eio.Promise.create () in
    let calls = ref 0 and source_inputs = ref 0 in
    let module TM = Masc.Transport_metrics in
    Eio.Fiber.first
      (fun () -> Eio.Switch.run (fun sw ->
        Input.subscribe ~sw ~base_path:root (fun input ->
          if Server_observation_refresh.affects Server_observation_refresh.Transport_health input then (
            if input = Input.Transport_state then incr source_inputs;
            if Eio.Stream.is_empty changes then Eio.Stream.add changes ()));
        Proactive_refresh.start_on_change_or_deadline ~sw
          ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) ~changes
          ~config:(Proactive_refresh.default_config ~label:"transport-source-to-reader" ~interval_s:30.0)
          ~compute:(fun () -> incr calls; TM.transport_health_json ())
          ~next_deadline:(fun _ -> None)
          ~on_result:(fun json ->
            Sse.sync_transport_snapshot ();
            TM.observe_broadcast_duration 0.001;
            Sse.broadcast_to_sse_runtime_observers authority
              (`Assoc ["type", `String "transport_health_snapshot"; "payload", json]);
            Eio.Stream.add reads json);
        Eio.Promise.await never))
      (fun () ->
        let initial = Eio.Stream.take reads in
        Eio.Fiber.yield ();
        check bool "healthy transport observation arms no timer" false (Eio_mock.Clock.try_advance clock);
        let open Yojson.Safe.Util in
        let accepted json = json |> member "http_listener" |> member "accepted_total" |> to_int in
        TM.record_http_accept ~mode:"h1";
        let updated = Eio.Stream.take reads in
        check int "actual connection commit reaches the production input" (accepted initial + 1) (accepted updated);
        Masc.Https_listener_metrics.record_started ();
        let tls = Eio.Stream.take reads in
        check string "HTTPS lifecycle reaches the same typed input" "listening"
          (tls |> member "https_listener" |> member "status" |> to_string);
        Eio.Fiber.yield ();
        check int "computed snapshots and mirror updates do not feed back" 3 !calls;
        check bool "the quiet worker has no periodic deadline" false (Eio_mock.Clock.try_advance clock));
    let before = !source_inputs in
    TM.record_http_connection_closed ~mode:"h1";
    Masc.Https_listener_metrics.record_stopped ();
    check int "normal switch release unsubscribes both source leaves" before !source_inputs)
;;

let () =
  run "server observation inputs"
    [ "wire", [ test_case "exact scoped identities" `Quick test_exact_input_identities
              ; test_case "outputs are excluded" `Quick test_outputs_are_not_inputs
              ; test_case "notification envelopes are exact" `Quick test_notification_envelopes_are_exact ]
    ; "execution sources", [ test_case "message identity and delivery are typed" `Quick test_message_input_is_typed
                            ; test_case "actual heartbeat scope and release" `Quick test_agent_heartbeat_reaches_only_its_workspace ]
    ; "publication", [ test_case "non-external source and release" `Quick test_nonexternal_scope_and_release
                     ; test_case "instance and presence boundaries" `Quick test_internal_scope_and_presence_bypass
                     ; test_case "listener failure keeps receipt" `Quick test_listener_failure_cannot_replace_publication
                     ; test_case "actual caller cancellation remains" `Quick test_listener_preserves_the_callers_actual_cancellation
                     ; test_case "source to worker excludes feedback" `Quick test_source_to_change_worker_without_output_feedback
                     ; test_case "transport lifecycle reaches worker without delivery feedback" `Quick test_transport_lifecycle_to_worker_without_delivery_feedback
                     ; test_case "real Board write wakes the scoped worker" `Quick test_real_board_writer_to_observation_worker
                     ; test_case "real MCP tool notification is decoded" `Quick test_real_tools_notification_is_an_input
                     ; test_case "real telemetry collector sample is decoded" `Quick test_real_telemetry_sample_is_an_input ] ]
