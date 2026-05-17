(** Round-trip + topic-stability tests for [Session_lifecycle_event.t]
    (RFC-0099 PR-2).

    Pins down the JSON encoding so dashboards / consumers can pattern
    match on a stable shape. Adding a new variant requires touching
    these tests, which forces RFC-level discussion (same discipline as
    {!test_mcp_error_code} for RFC-0098). *)

open Alcotest
module E = Masc_mcp.Session_lifecycle_event

let pp_evt fmt e = E.pp fmt e

let evt_eq a b =
  Yojson.Safe.to_string (E.to_yojson a)
  = Yojson.Safe.to_string (E.to_yojson b)

let evt : E.t Alcotest.testable = testable pp_evt evt_eq

let round_trip e =
  match E.of_yojson (E.to_yojson e) with
  | Ok e' -> e'
  | Error msg ->
      Alcotest.failf "round-trip failed for %a: %s" pp_evt e msg

let samples : E.t list =
  [
    Open { transport = SSE ; session_id = "s1" ; origin = "https://x" };
    Open { transport = WS ; session_id = "s2" ; origin = "*" };
    Upgrade
      { transport_from = SSE ; transport_to = WS ; session_id = "s3" };
    Resume
      {
        transport = SSE ;
        session_id = "s4" ;
        last_event_id = Some "evt-1234" ;
        replayed = 7 ;
      };
    Resume
      {
        transport = WebRTC ;
        session_id = "s5" ;
        last_event_id = None ;
        replayed = 0 ;
      };
    Evict { transport = SSE ; session_id = "s6" ; reason = Cap_exceeded };
    Evict { transport = WS ; session_id = "s7" ; reason = Idle_timeout };
    Evict
      { transport = GRPC ; session_id = "s8" ; reason = Backpressure };
    Evict
      { transport = SSE ; session_id = "s9" ; reason = Policy_revoked };
    Close
      { transport = SSE ; session_id = "s10" ; reason = Client_disconnected };
    Close
      { transport = WS ; session_id = "s11" ; reason = Server_shutdown };
    Close
      {
        transport = SSE ;
        session_id = "s12" ;
        reason = Server_error "boom" ;
      };
    Close
      {
        transport = SSE ;
        session_id = "s13" ;
        reason = Evicted Backpressure ;
      };
  ]

let test_round_trip () =
  List.iter (fun e -> check evt "round-trip" e (round_trip e)) samples

let test_topic_stable () =
  check string "bus topic SSOT" "session_lifecycle" E.bus_topic

let test_transport_round_trip () =
  List.iter
    (fun t ->
      let s = E.transport_to_string t in
      match E.transport_of_string s with
      | Some t' when t' = t -> ()
      | Some _ -> Alcotest.failf "transport drift: %s" s
      | None -> Alcotest.failf "transport_of_string None for %s" s)
    [ E.SSE; WS; GRPC; WebRTC ]

let test_evict_reason_round_trip () =
  List.iter
    (fun r ->
      let s = E.evict_reason_to_string r in
      match E.evict_reason_of_string s with
      | Some r' when r' = r -> ()
      | Some _ -> Alcotest.failf "evict_reason drift: %s" s
      | None ->
          Alcotest.failf "evict_reason_of_string None for %s" s)
    [ E.Cap_exceeded; Idle_timeout; Backpressure; Policy_revoked ]

let test_unknown_kind_rejected () =
  let bad = `Assoc [ ("kind", `String "definitely_not_a_kind") ] in
  match E.of_yojson bad with
  | Error _ -> ()
  | Ok _ ->
      Alcotest.fail
        "of_yojson should reject unknown kind rather than silently \
         collapse"

let test_unknown_transport_rejected () =
  let bad =
    `Assoc
      [
        ("kind", `String "open") ;
        ("transport", `String "carrier_pigeon") ;
        ("session_id", `String "s") ;
        ("origin", `String "*") ;
      ]
  in
  match E.of_yojson bad with
  | Error _ -> ()
  | Ok _ ->
      Alcotest.fail
        "of_yojson should reject unknown transport rather than \
         silently collapse"

let test_close_reason_kind_labels () =
  let cases =
    [
      (E.Client_disconnected, "client_disconnected") ;
      (E.Server_shutdown, "server_shutdown") ;
      (E.Server_error "x", "server_error") ;
      (E.Evicted E.Backpressure, "evicted") ;
    ]
  in
  List.iter
    (fun (r, expected) -> check string expected expected (E.close_reason_kind r))
    cases

let () =
  Alcotest.run "Session_lifecycle_event"
    [
      ( "wire shape",
        [
          test_case "round-trip all variants" `Quick test_round_trip ;
          test_case "bus_topic stable" `Quick test_topic_stable ;
          test_case "transport round-trip" `Quick test_transport_round_trip ;
          test_case "evict_reason round-trip" `Quick test_evict_reason_round_trip ;
          test_case "close_reason kind labels" `Quick test_close_reason_kind_labels ;
        ] ) ;
      ( "rejection",
        [
          test_case "unknown kind" `Quick test_unknown_kind_rejected ;
          test_case "unknown transport" `Quick test_unknown_transport_rejected ;
        ] ) ;
    ]
