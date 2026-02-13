open Alcotest

let test_unregister_if_current () =
  let open Masc_mcp.Sse in
  let session_id = "test_session" in
  let noop _ = () in

  let (id1, _) = register session_id ~push:noop ~last_event_id:0 in
  check bool "registered" true (exists session_id);

  (* Re-register same session_id (simulates reconnect) *)
  let (id2, _) = register session_id ~push:noop ~last_event_id:0 in
  check bool "still registered" true (exists session_id);

  (* Old connection cleanup must not unregister the new connection *)
  unregister_if_current session_id id1;
  check bool "new connection survives old cleanup" true (exists session_id);

  (* Current connection cleanup should unregister *)
  unregister_if_current session_id id2;
  check bool "unregistered" false (exists session_id);
  ()

let test_cleanup_stale_respects_touch () =
  let open Masc_mcp.Sse in
  let stale_sid = "stale_session_" ^ string_of_int (Random.int 1000000) in
  let alive_sid = "alive_session_" ^ string_of_int (Random.int 1000000) in
  let noop _ = () in
  let (_id1, _) = register stale_sid ~push:noop ~last_event_id:0 in
  let (_id2, _) = register alive_sid ~push:noop ~last_event_id:0 in

  Unix.sleepf 0.05;
  touch alive_sid;

  let evicted = cleanup_stale ~max_age_s:0.02 () in
  check bool "stale evicted" true (List.mem stale_sid evicted);
  check bool "stale removed" false (exists stale_sid);
  check bool "touched connection survives" true (exists alive_sid);

  unregister alive_sid

let test_admit_connection_session_cooldown () =
  let open Masc_mcp.Sse in
  reset_admission_state_for_test ();
  let sid = "cooldown_session" in
  (match admit_connection_at
           ~now:100.0
           ~min_interval_s:1.0
           ~window_s:10.0
           ~max_in_window:100
           sid with
   | Allowed -> ()
   | Rejected _ -> fail "first connection should be allowed");
  match admit_connection_at
          ~now:100.2
          ~min_interval_s:1.0
          ~window_s:10.0
          ~max_in_window:100
          sid with
  | Allowed -> fail "immediate reconnect should be rejected"
  | Rejected { reason = Session_cooldown; retry_ms } ->
      check bool "retry_ms positive" true (retry_ms > 0)
  | Rejected { reason = Global_rate_limit; _ } ->
      fail "unexpected global rate limit"

let test_admit_connection_global_rate_limit () =
  let open Masc_mcp.Sse in
  reset_admission_state_for_test ();
  let cfg_min = 0.0 in
  let cfg_window = 5.0 in
  let cfg_max = 2 in
  (match admit_connection_at ~now:200.0 ~min_interval_s:cfg_min ~window_s:cfg_window ~max_in_window:cfg_max "a" with
   | Allowed -> ()
   | Rejected _ -> fail "first connection should be allowed");
  (match admit_connection_at ~now:200.1 ~min_interval_s:cfg_min ~window_s:cfg_window ~max_in_window:cfg_max "b" with
   | Allowed -> ()
   | Rejected _ -> fail "second connection should be allowed");
  match admit_connection_at ~now:200.2 ~min_interval_s:cfg_min ~window_s:cfg_window ~max_in_window:cfg_max "c" with
  | Allowed -> fail "third connection in window should be rejected"
  | Rejected { reason = Global_rate_limit; retry_ms } ->
      check bool "retry_ms positive" true (retry_ms > 0)
  | Rejected { reason = Session_cooldown; _ } ->
      fail "unexpected session cooldown"

let test_admit_connection_window_reopens () =
  let open Masc_mcp.Sse in
  reset_admission_state_for_test ();
  let cfg_min = 0.0 in
  let cfg_window = 1.0 in
  let cfg_max = 1 in
  (match admit_connection_at ~now:300.0 ~min_interval_s:cfg_min ~window_s:cfg_window ~max_in_window:cfg_max "a" with
   | Allowed -> ()
   | Rejected _ -> fail "first connection should be allowed");
  (match admit_connection_at ~now:300.1 ~min_interval_s:cfg_min ~window_s:cfg_window ~max_in_window:cfg_max "b" with
   | Allowed -> fail "should still be rate limited in window"
   | Rejected { reason = Global_rate_limit; _ } -> ()
   | Rejected { reason = Session_cooldown; _ } -> fail "unexpected session cooldown");
  match admit_connection_at ~now:301.2 ~min_interval_s:cfg_min ~window_s:cfg_window ~max_in_window:cfg_max "b" with
  | Allowed -> ()
  | Rejected _ -> fail "window should allow connection again"

let () =
  run "sse"
    [
      ("unregister_if_current", [test_case "guards reconnect" `Quick test_unregister_if_current]);
      ("cleanup_stale", [test_case "uses idle time" `Quick test_cleanup_stale_respects_touch]);
      ("admit_connection", [
        test_case "session cooldown" `Quick test_admit_connection_session_cooldown;
        test_case "global rate limit" `Quick test_admit_connection_global_rate_limit;
        test_case "window reopens" `Quick test_admit_connection_window_reopens;
      ]);
    ]
