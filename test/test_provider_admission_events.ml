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

(* Memory and Keeper calls name different models but share one endpoint.
   Queue memory first: the service order must retain judgment priority,
   allow the Keeper to pass the backlog, and still complete memory work. *)
let fleet_grant_order ~run_limit =
  Eio_mock.Backend.run @@ fun () ->
  let base =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"keeper-model"
      ~base_url:(match run_limit with
        | None -> "http://fleet-fifo.test:1"
        | Some _ -> "http://fleet-fair.test:1")
      ~max_concurrent_requests:1
      ?admission_priority_run_limit:run_limit
      ()
  in
  let librarian =
    { base with
      model_id = "memory-model"
    ; admission_class = Standalone_lane.admission_class Librarian
    }
  in
  let judgment =
    { base with
      model_id = "judgment-model"
    ; admission_class = Standalone_lane.admission_class Verifier
    }
  in
  let granted = ref [] in
  Eio.Switch.run (fun sw ->
    let release, resolve_release = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      Admission.with_admission ~config:base (fun () -> Eio.Promise.await release));
    List.iter (fun (label, config) ->
      Eio.Fiber.fork ~sw (fun () ->
        Admission.with_admission ~config (fun () -> granted := label :: !granted)))
      [ "memory-1", librarian; "memory-2", librarian; "memory-3", librarian
      ; "keeper-1", base; "keeper-2", base; "keeper-3", base
      ; "judgment-1", judgment; "judgment-2", judgment
      ];
    (match Admission.snapshot_for ~config:base with
     | Some snapshot ->
       check int "all models share the occupied endpoint queue" 8 snapshot.queue_length
     | None -> fail "the endpoint scheduler was not created");
    Eio.Promise.resolve resolve_release ());
  (match Admission.snapshot_for ~config:base with
   | Some snapshot ->
     check int "all permits returned" 0 snapshot.active;
     check int "all three workloads completed" 0 snapshot.queue_length
   | None -> fail "the endpoint scheduler disappeared");
  List.rev !granted
;;

let test_keeper_calls_pass_the_memory_backlog_without_starving_it () =
  check (list string) "judgments, Keeper calls and memory all receive service"
    [ "judgment-1"; "memory-1"; "keeper-1"; "memory-2"
    ; "judgment-2"; "memory-3"; "keeper-2"; "keeper-3" ]
    (fleet_grant_order ~run_limit:(Some 1))
;;

let test_a_provider_without_fairness_keeps_the_fleet_in_arrival_order () =
  check (list string) "an undeclared policy keeps one FIFO"
    [ "memory-1"; "memory-2"; "memory-3"
    ; "keeper-1"; "keeper-2"; "keeper-3"; "judgment-1"; "judgment-2" ]
    (fleet_grant_order ~run_limit:None)
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
        ; test_case "Keeper calls pass the memory backlog without starving it"
            `Quick test_keeper_calls_pass_the_memory_backlog_without_starving_it
        ; test_case "a provider without fairness keeps fleet arrival order"
            `Quick test_a_provider_without_fairness_keeps_the_fleet_in_arrival_order
        ] )
    ]
;;
