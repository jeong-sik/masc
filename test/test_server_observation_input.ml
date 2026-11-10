open Alcotest

module Input = Server_observation_input
module Sse = Masc.Sse
module Dataset = Masc.Workspace_dataset_event
module Goals = Masc.Goal_projection_broadcast
module Schedules = Masc.Schedule_invalidation_event
module Slices = Masc.Dashboard_event_slices

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

let () =
  run "server observation inputs"
    [ "wire", [ test_case "exact scoped identities" `Quick test_exact_input_identities
              ; test_case "outputs are excluded" `Quick test_outputs_are_not_inputs ]
    ; "publication", [ test_case "non-external source and release" `Quick test_nonexternal_scope_and_release
                     ; test_case "instance and presence boundaries" `Quick test_internal_scope_and_presence_bypass
                     ; test_case "listener failure keeps receipt" `Quick test_listener_failure_cannot_replace_publication
                     ; test_case "actual caller cancellation remains" `Quick test_listener_preserves_the_callers_actual_cancellation
                     ; test_case "source to worker excludes feedback" `Quick test_source_to_change_worker_without_output_feedback ] ]
