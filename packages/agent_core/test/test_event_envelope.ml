(** Unit tests for Event_envelope — canonical event envelope for
    cross-runtime causality evidence.

    Pure data: ID generation, source_clock variant round-trip,
    record construction with defaults, and JSON serialisation. *)

open Agent_sdk
open Alcotest

(* ── fresh_id ──────────────────────────────────────────── *)

let test_fresh_id_unique () =
  let a = Event_envelope.fresh_id () in
  let b = Event_envelope.fresh_id () in
  check bool "non-empty" true (String.length a > 0);
  check bool "two ids differ" true (a <> b)
;;

(* ── source_clock_to_string / of_string round-trip ─────── *)

let test_source_clock_roundtrip () =
  let cases = Event_envelope.[ Wall; Monotonic; Logical; Unknown ] in
  List.iter
    (fun clk ->
       let s = Event_envelope.source_clock_to_string clk in
       match Event_envelope.source_clock_of_string s with
       | Ok back -> check bool ("round-trip " ^ s) true (back = clk)
       | Error msg -> failf "round-trip failed for %s: %s" s msg)
    cases
;;

let test_source_clock_invalid () =
  match Event_envelope.source_clock_of_string "garbage" with
  | Ok _ -> fail "expected Error for garbage input"
  | Error _ -> ()
;;

(* ── make defaults ──────────────────────────────────────── *)

let test_make_defaults () =
  let t = Event_envelope.make () in
  check bool "event_id non-empty" true (String.length t.event_id > 0)
;;

let test_make_explicit () =
  let t =
    Event_envelope.make
      ~event_id:"e1"
      ~correlation_id:"c1"
      ~run_id:"r1"
      ~event_time:100.0
      ~observed_at:200.0
      ~seq:5
      ~parent_event_id:"e0"
      ~caused_by:"trigger"
      ~source_clock:Event_envelope.Monotonic
      ()
  in
  check string "event_id" "e1" t.event_id;
  check string "correlation_id" "c1" t.correlation_id;
  check string "run_id" "r1" t.run_id;
  check (float 1e-9) "event_time" 100.0 t.event_time;
  check (float 1e-9) "observed_at" 200.0 t.observed_at;
  check (option int) "seq" (Some 5) t.seq;
  check (option string) "parent_event_id" (Some "e0") t.parent_event_id;
  check (option string) "caused_by" (Some "trigger") t.caused_by;
  check bool "source_clock = Monotonic" true (t.source_clock = Event_envelope.Monotonic)
;;

(* ── to_json / of_json round-trip ──────────────────────── *)

let test_json_roundtrip_minimal () =
  let t = Event_envelope.make ~event_id:"e1" ~run_id:"r1" () in
  let json = Event_envelope.to_json t in
  match Event_envelope.of_json json with
  | Ok t2 ->
    check string "event_id preserved" t.event_id t2.event_id;
    check string "run_id preserved" t.run_id t2.run_id
  | Error msg -> failf "of_json failed: %s" msg
;;

let test_json_roundtrip_full () =
  let t =
    Event_envelope.make
      ~event_id:"e1"
      ~correlation_id:"c1"
      ~run_id:"r1"
      ~event_time:100.0
      ~observed_at:200.0
      ~seq:5
      ~parent_event_id:"e0"
      ~caused_by:"trigger"
      ~source_clock:Event_envelope.Logical
      ()
  in
  let json = Event_envelope.to_json t in
  match Event_envelope.of_json json with
  | Ok t2 ->
    check string "event_id" t.event_id t2.event_id;
    check string "correlation_id" t.correlation_id t2.correlation_id;
    check string "run_id" t.run_id t2.run_id;
    check (option int) "seq" t.seq t2.seq;
    check (option string) "parent_event_id" t.parent_event_id t2.parent_event_id;
    check (option string) "caused_by" t.caused_by t2.caused_by;
    check bool "source_clock preserved" true (t.source_clock = t2.source_clock)
  | Error msg -> failf "of_json failed: %s" msg
;;

let test_of_json_invalid () =
  let bad = `String "not an object" in
  match Event_envelope.of_json bad with
  | Ok _ -> fail "expected Error for non-object"
  | Error _ -> ()
;;

let () =
  run
    "Event_envelope"
    [ "fresh_id", [ test_case "uniqueness + non-empty" `Quick test_fresh_id_unique ]
    ; ( "source_clock"
      , [ test_case "round-trip all 4 variants" `Quick test_source_clock_roundtrip
        ; test_case "invalid input → Error" `Quick test_source_clock_invalid
        ] )
    ; ( "make"
      , [ test_case "defaults produce valid envelope" `Quick test_make_defaults
        ; test_case "explicit fields preserved" `Quick test_make_explicit
        ] )
    ; ( "json"
      , [ test_case "minimal round-trip" `Quick test_json_roundtrip_minimal
        ; test_case "full-field round-trip" `Quick test_json_roundtrip_full
        ; test_case "invalid input → Error" `Quick test_of_json_invalid
        ] )
    ]
;;
