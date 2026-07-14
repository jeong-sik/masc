(** Runtime lifecycle observations emitted alongside OAS checkpoints. *)

open Masc
open Alcotest

module CP = Runtime_oas_checkpoint

let custom_payload_fields expected_topic (event : Agent_sdk.Event_bus.event) =
  match event.payload with
  | Agent_sdk.Event_bus.Custom (topic, `Assoc fields) ->
    check string "lifecycle topic" expected_topic topic;
    fields
  | Agent_sdk.Event_bus.Custom (topic, _) ->
    failf "expected object payload for %s" topic
  | _ -> fail "expected custom lifecycle event"

let test_publish_lifecycle_reaches_masc_bus_with_max_tokens_intent () =
  Eio_main.run @@ fun _env ->
  let bus = Agent_sdk.Event_bus.create () in
  let subscription =
    Agent_sdk_metrics_bridge.subscribe
      ~capacity:256
      ~overflow:Agent_sdk.Event_bus.Drop_oldest
      ~purpose:"runtime-lifecycle-test"
      bus
  in
  Masc_event_bus.set bus;
  Fun.protect
    ~finally:(fun () -> Agent_sdk.Event_bus.unsubscribe bus subscription)
    (fun () ->
      CP.publish_lifecycle
        ~name:"keeper-a"
        ~event:"build"
        ~detail:"omitted"
        ~attrs:(Runtime_max_tokens.telemetry_fields None)
        ();
      CP.publish_lifecycle
        ~name:"keeper-a"
        ~event:"completed"
        ~detail:"explicit"
        ~attrs:(Runtime_max_tokens.telemetry_fields (Some 4096))
        ();
      match Agent_sdk.Event_bus.drain subscription with
      | [ omitted; explicit ] ->
        let omitted_fields =
          custom_payload_fields "masc.oas_worker.build" omitted
        in
        check (option (of_pp Yojson.Safe.pp)) "omitted value is observable null"
          (Some `Null)
          (List.assoc_opt "max_tokens" omitted_fields);
        check (option string) "omitted source"
          (Some "omitted")
          (Option.bind
             (List.assoc_opt "max_tokens_source" omitted_fields)
             Yojson.Safe.Util.to_string_option);
        let explicit_fields =
          custom_payload_fields "masc.oas_worker.completed" explicit
        in
        check (option (of_pp Yojson.Safe.pp)) "explicit value is preserved"
          (Some (`Int 4096))
          (List.assoc_opt "max_tokens" explicit_fields);
        check (option string) "explicit source"
          (Some "explicit_override")
          (Option.bind
             (List.assoc_opt "max_tokens_source" explicit_fields)
             Yojson.Safe.Util.to_string_option)
      | events -> failf "expected two lifecycle events, got %d" (List.length events))

let () =
  run "oas_worker_exec_checkpoint"
    [
      ( "runtime_lifecycle",
        [
          test_case
            "publishes to MASC bus with max_tokens intent"
            `Quick
            test_publish_lifecycle_reaches_masc_bus_with_max_tokens_intent;
        ] );
    ]
