(* Provider admission waits reach the MASC bus as one event per queued
   request, with the payload the relay writes to agent-core-events. *)
open Alcotest
open Masc
module Admission = Llm_provider.Provider_admission

let custom_payload (event : Agent_core.Event_bus.event) =
  match event.payload with
  | Agent_core.Event_bus.Custom (name, json) -> name, json
  | _ -> fail "expected a Custom event"
;;

let test_the_payload_names_the_wait () =
  let name, json =
    custom_payload
      (Provider_admission_events.event
         { Admission.kind = "glm"
         ; provider_id = Some "glm-coding"
         ; model_id = "glm-5.3"
         ; admission_class = Priority
         ; waited_ms = Some 1250.0
         ; outcome = Wait_granted
         })
  in
  check string "wire name" "masc.provider_admission.waited" name;
  check
    string
    "payload"
    {|{"provider_id":"glm-coding","kind":"glm","model":"glm-5.3","admission_class":"priority","waited_ms":1250.0,"outcome":"granted"}|}
    (Yojson.Safe.to_string json);
  let _, unmeasured =
    custom_payload
      (Provider_admission_events.event
         { Admission.kind = "openai_compat"
         ; provider_id = None
         ; model_id = "m"
         ; admission_class = Standard
         ; waited_ms = None
         ; outcome = Wait_expired
         })
  in
  check
    string
    "missing facts are null"
    {|{"provider_id":null,"kind":"openai_compat","model":"m","admission_class":"standard","waited_ms":null,"outcome":"expired"}|}
    (Yojson.Safe.to_string unmeasured)
;;

(* One request holds the only permit while a second queues behind it. *)
let queue_one_request ~clock config =
  let occupied, occupied_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  Eio.Fiber.both
    (fun () ->
       Admission.with_admission ~config (fun () ->
         Eio.Promise.resolve occupied_resolver ();
         Eio.Promise.await release))
    (fun () ->
       Eio.Promise.await occupied;
       Eio.Fiber.both
         (fun () -> Admission.with_admission ~config (fun () -> ()))
         (fun () ->
            Eio.Time.sleep clock 0.02;
            Eio.Promise.resolve release_resolver ()))
;;

let test_an_installed_bus_receives_each_queued_wait () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let config =
    { (Llm_provider.Provider_config.make
         ~kind:Llm_provider.Provider_config.OpenAI_compat
         ~model_id:"admission-events-model"
         ~base_url:"http://admission-events.test:1"
         ~request_path:"/v1/chat/completions"
         ~max_concurrent_requests:1
         ())
      with
      provider_id = Some "admission-events-provider"
    }
  in
  let bus = Agent_core.Event_bus.create () in
  let subscription =
    Runtime_event_bus.subscribe
      ~capacity:16
      ~overflow:Agent_core.Event_bus.Drop_oldest
      ~purpose:"admission_events_test"
      ~filter:(Agent_core.Event_bus.filter_topic Provider_admission_events.wire_name)
      bus
  in
  let drained () = Runtime_event_bus.drain subscription |> List.map custom_payload in
  Eio.Switch.run (fun sw ->
    Provider_admission_events.install ~sw bus;
    queue_one_request ~clock config;
    match drained () with
    | [ (_, json) ] ->
      let field name = Yojson.Safe.Util.member name json in
      check string "outcome" "granted" (Yojson.Safe.Util.to_string (field "outcome"));
      check
        string
        "provider id"
        "admission-events-provider"
        (Yojson.Safe.Util.to_string (field "provider_id"))
    | events -> failf "expected one wait event, got %d" (List.length events));
  queue_one_request ~clock config;
  check int "nothing is published once the switch is released" 0 (List.length (drained ()))
;;

let () =
  run
    "Provider admission events"
    [ ( "events"
      , [ test_case "the payload names the wait" `Quick test_the_payload_names_the_wait
        ; test_case
            "an installed bus receives each queued wait"
            `Quick
            test_an_installed_bus_receives_each_queued_wait
        ] )
    ]
;;
