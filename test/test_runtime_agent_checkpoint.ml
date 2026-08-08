(** Runtime lifecycle observations emitted alongside Agent core checkpoints. *)

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

let bridged_payload_fields expected_event_type event =
  match Keeper_event_bridge.native_event_to_json event with
  | Some (`Assoc fields) ->
    check (option string) "SSE event type" (Some expected_event_type)
      (Option.bind
         (List.assoc_opt "event_type" fields)
         Yojson.Safe.Util.to_string_option);
    (match List.assoc_opt "payload" fields with
     | Some (`Assoc payload_fields) -> payload_fields
     | _ -> fail "expected bridged lifecycle payload")
  | Some _ -> fail "expected bridged lifecycle object"
  | None -> fail "runtime lifecycle event must reach the bridge"

let test_publish_lifecycle_reaches_masc_bus_with_max_tokens_intent () =
  Eio_main.run @@ fun _env ->
  let bus = Agent_sdk.Event_bus.create () in
  let subscription =
    Runtime_event_bus.subscribe
      ~capacity:256
      ~overflow:Agent_sdk.Event_bus.Drop_oldest
      ~purpose:"runtime-lifecycle-test"
      bus
  in
  Event_bus_slots.set_masc bus;
  Fun.protect
    ~finally:(fun () -> Runtime_event_bus.unsubscribe bus subscription)
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
      match Runtime_event_bus.drain subscription with
      | [ omitted; explicit ] ->
        let omitted_fields =
          custom_payload_fields "masc.runtime_agent.build" omitted
        in
        let bridged_omitted_fields =
          bridged_payload_fields "masc:runtime_agent:build" omitted
        in
        check (option (of_pp Yojson.Safe.pp)) "omitted value is observable null"
          (Some `Null)
          (List.assoc_opt "max_tokens" omitted_fields);
        check (option (of_pp Yojson.Safe.pp)) "bridged omitted value"
          (Some `Null)
          (List.assoc_opt "max_tokens" bridged_omitted_fields);
        check (option string) "omitted source"
          (Some "omitted")
          (Option.bind
             (List.assoc_opt "max_tokens_source" omitted_fields)
             Yojson.Safe.Util.to_string_option);
        let explicit_fields =
          custom_payload_fields "masc.runtime_agent.completed" explicit
        in
        let bridged_explicit_fields =
          bridged_payload_fields "masc:runtime_agent:completed" explicit
        in
        check (option (of_pp Yojson.Safe.pp)) "explicit value is preserved"
          (Some (`Int 4096))
          (List.assoc_opt "max_tokens" explicit_fields);
        check (option (of_pp Yojson.Safe.pp)) "bridged explicit value"
          (Some (`Int 4096))
          (List.assoc_opt "max_tokens" bridged_explicit_fields);
        check (option string) "explicit source"
          (Some "explicit_override")
          (Option.bind
             (List.assoc_opt "max_tokens_source" explicit_fields)
             Yojson.Safe.Util.to_string_option)
      | events -> failf "expected two lifecycle events, got %d" (List.length events))

let () =
  run "runtime_agent_checkpoint"
    [
      ( "runtime_lifecycle",
        [
          test_case
            "publishes to MASC bus with max_tokens intent"
            `Quick
            test_publish_lifecycle_reaches_masc_bus_with_max_tokens_intent;
        ] );
    ]
