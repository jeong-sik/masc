(** Tests for Journal_bridge — Durable_event → Event_bus projection. *)

open Alcotest
open Agent_sdk

let append_ok journal event = Durable_event.append journal event |> Result.get_ok
let ts = 1711234567.0

let projection_name evt =
  let name, _ = Journal_bridge.projection_of_event evt in
  name
;;

let projection_payload evt =
  let _, payload = Journal_bridge.projection_of_event evt in
  payload
;;

(* ── Projection: name and payload shape ─────────────── *)

let test_turn_started_projection () =
  let evt = Durable_event.Turn_started { turn = 3; timestamp = ts } in
  check string "name" "durable.turn_started" (projection_name evt);
  match projection_payload evt with
  | `Assoc fields ->
    check
      int
      "turn"
      3
      (match List.assoc_opt "turn" fields with
       | Some (`Int n) -> n
       | _ -> -1)
  | _ -> fail "expected Assoc"
;;

let test_llm_request_projection () =
  let evt = Durable_event.Llm_request { turn = 1; model = "dashscope"; timestamp = ts } in
  check string "name" "durable.llm_request" (projection_name evt);
  match projection_payload evt with
  | `Assoc fields ->
    check
      bool
      "input_tokens absent before response"
      false
      (List.mem_assoc "input_tokens" fields);
    check
      string
      "model"
      "dashscope"
      (match List.assoc_opt "model" fields with
       | Some (`String s) -> s
       | _ -> "")
  | _ -> fail "expected Assoc"
;;

let test_tool_completed_projection () =
  let evt =
    Durable_event.Tool_completed
      { turn = 2
      ; tool_name = "read"
      ; idempotency_key = "k1"
      ; output_json = `String "ok"
      ; is_error = false
      ; duration_ms = 12.5
      ; timestamp = ts
      }
  in
  check string "name" "durable.tool_completed" (projection_name evt);
  match projection_payload evt with
  | `Assoc fields ->
    check
      bool
      "is_error"
      false
      (match List.assoc_opt "is_error" fields with
       | Some (`Bool b) -> b
       | _ -> true)
  | _ -> fail "expected Assoc"
;;

let test_all_variants_project () =
  let variants =
    [ Durable_event.Turn_started { turn = 1; timestamp = ts }
    ; Llm_request { turn = 1; model = "m"; timestamp = ts }
    ; Llm_response
        { turn = 1
        ; input_tokens = Some 10
        ; output_tokens = Some 5
        ; stop_reason = "end_turn"
        ; duration_ms = 100.0
        ; timestamp = ts
        }
    ; Tool_called
        { turn = 1
        ; tool_name = "t"
        ; idempotency_key = "k"
        ; input_hash = "h"
        ; timestamp = ts
        }
    ; Tool_completed
        { turn = 1
        ; tool_name = "t"
        ; idempotency_key = "k"
        ; output_json = `Null
        ; is_error = false
        ; duration_ms = 1.0
        ; timestamp = ts
        }
    ; State_transition { from_state = "a"; to_state = "b"; reason = "r"; timestamp = ts }
    ; Checkpoint_saved { checkpoint_id = "c"; timestamp = ts }
    ; Error_occurred { turn = 1; error_domain = "Api"; detail = "d"; timestamp = ts }
    ]
  in
  List.iter
    (fun evt ->
       let name, _ = Journal_bridge.projection_of_event evt in
       check
         bool
         (Printf.sprintf "name has durable. prefix: %s" name)
         true
         (String.length name > 8 && String.sub name 0 8 = "durable."))
    variants
;;

(* ── End-to-end: bridge via on_append ──────────────── *)

let test_make_publishes_to_bus () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:2 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config bus in
  let journal = Durable_event.create ~on_append:(Journal_bridge.make ~bus ()) () in
  append_ok journal (Turn_started { turn = 1; timestamp = ts });
  append_ok
    journal
    (Error_occurred { turn = 1; error_domain = "Api"; detail = "boom"; timestamp = ts });
  let events = Event_bus.drain sub in
  check int "published count" 2 (List.length events);
  let names =
    List.map
      (fun (e : Event_bus.event) ->
         match e.payload with
         | Custom (n, _) -> n
         | _ -> "non-custom")
      events
  in
  check (list string) "names" [ "durable.turn_started"; "durable.error_occurred" ] names
;;

let test_make_preserves_envelope () =
  Eio_main.run
  @@ fun _env ->
  let bus = Event_bus.create () in
  let config =
    Event_bus.subscription_config ~capacity:2 ~overflow:Event_bus.Drop_newest
    |> Result.get_ok
  in
  let sub = Event_bus.subscribe ~config bus in
  let corr = "corr-42" in
  let run_id = "run-42" in
  let journal =
    Durable_event.create
      ~on_append:(Journal_bridge.make ~bus ~correlation_id:corr ~run_id ())
      ()
  in
  append_ok journal (Turn_started { turn = 1; timestamp = ts });
  append_ok
    journal
    (Error_occurred { turn = 1; error_domain = "Api"; detail = "boom"; timestamp = ts });
  let events = Event_bus.drain sub in
  check int "count" 2 (List.length events);
  List.iter
    (fun (e : Event_bus.event) ->
       check string "correlation_id preserved" corr e.meta.correlation_id;
       check string "run_id preserved" run_id e.meta.run_id)
    events
;;

let () =
  run
    "Journal_bridge"
    [ ( "projection"
      , [ test_case "turn_started" `Quick test_turn_started_projection
        ; test_case "llm_request" `Quick test_llm_request_projection
        ; test_case "tool_completed" `Quick test_tool_completed_projection
        ; test_case "all variants have durable. prefix" `Quick test_all_variants_project
        ] )
    ; ( "bridge"
      , [ test_case "make publishes to bus" `Quick test_make_publishes_to_bus
        ; test_case "make preserves envelope" `Quick test_make_preserves_envelope
        ] )
    ]
;;
