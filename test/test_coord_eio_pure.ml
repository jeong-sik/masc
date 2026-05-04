(** Pure-function unit tests for [Coord_eio].

    Covers the deterministic helpers that don't touch Eio fibers, the
    filesystem backend, or any Eio context: key formatters, the
    [event_type] string mapping, and the [room_state] JSON round-trip. *)

open Masc_mcp
module CE = Coord_eio

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_int label expected actual =
  Alcotest.(check int) label expected actual

let check_string_list label expected actual =
  Alcotest.(check (list string)) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

(* ── Key formatters ──────────────────────────────────────────────────── *)

let test_agent_key () =
  check_string "agent_key alice" "agents:alice" (CE.agent_key "alice")

let test_message_key_zero_pads () =
  check_string "message_key 7 → 6-digit zero-padded"
    "messages:000007" (CE.message_key 7)

let test_message_key_large () =
  check_string "message_key 123456 → no truncation"
    "messages:123456" (CE.message_key 123456)

let test_lock_key () =
  check_string "lock_key resource-A"
    "locks:resource-A" (CE.lock_key "resource-A")

let test_event_key_zero_pads () =
  check_string "event_key 0 → 6-digit zero-padded"
    "events:000000" (CE.event_key 0)

(* ── event_type_to_string ────────────────────────────────────────────── *)

let test_event_type_strings () =
  check_string "AgentJoin"   "agent_join"   (CE.event_type_to_string CE.AgentJoin);
  check_string "AgentLeave"  "agent_leave"  (CE.event_type_to_string CE.AgentLeave);
  check_string "Broadcast"   "broadcast"    (CE.event_type_to_string CE.Broadcast);
  check_string "LockAcquire" "lock_acquire" (CE.event_type_to_string CE.LockAcquire);
  check_string "LockRelease" "lock_release" (CE.event_type_to_string CE.LockRelease)

(* ── room_state JSON round-trip ──────────────────────────────────────── *)

let test_default_room_state_round_trip () =
  let state = CE.default_room_state () in
  let json = CE.room_state_to_json state in
  match CE.room_state_of_json json with
  | Error msg -> Alcotest.fail ("default round-trip failed: " ^ msg)
  | Ok decoded ->
    check_string "protocol_version preserved"
      state.protocol_version decoded.protocol_version;
    check_string_list "active_agents preserved"
      state.active_agents decoded.active_agents;
    check_int "message_seq preserved"
      state.message_seq decoded.message_seq;
    check_int "event_seq preserved"
      state.event_seq decoded.event_seq;
    check_string "mode preserved"
      state.mode decoded.mode;
    check_bool "paused preserved"
      state.paused decoded.paused

let test_paused_room_state_round_trip () =
  let base = CE.default_room_state () in
  let state =
    { base with
      paused = true;
      paused_by = Some "alice";
      paused_at = Some 1234.5;
      pause_reason = Some "maintenance";
      active_agents = [ "alice"; "bob"; "carol" ];
      message_seq = 42;
      event_seq = 7;
    }
  in
  let json = CE.room_state_to_json state in
  match CE.room_state_of_json json with
  | Error msg -> Alcotest.fail ("paused round-trip failed: " ^ msg)
  | Ok decoded ->
    check_bool "paused=true preserved" true decoded.paused;
    check_string "paused_by preserved" "alice"
      (Option.value ~default:"<none>" decoded.paused_by);
    check_string "pause_reason preserved" "maintenance"
      (Option.value ~default:"<none>" decoded.pause_reason);
    check_string_list "active_agents preserved"
      [ "alice"; "bob"; "carol" ] decoded.active_agents;
    check_int "message_seq=42 preserved" 42 decoded.message_seq;
    check_int "event_seq=7 preserved" 7 decoded.event_seq

let test_room_state_of_json_missing_event_seq () =
  (* Backward-compat path: old state files without event_seq must default
     to 0 instead of failing — explicitly handled by Safe_ops.json_int in
     room_state_of_json. *)
  let json =
    `Assoc
      [
        ("protocol_version", `String "1.0.0");
        ("started_at", `Float 1.0);
        ("last_updated", `Float 2.0);
        ("active_agents", `List []);
        ("message_seq", `Int 0);
        (* event_seq intentionally omitted *)
        ("mode", `String "collaborative");
        ("paused", `Bool false);
        ("paused_by", `Null);
        ("paused_at", `Null);
        ("pause_reason", `Null);
      ]
  in
  match CE.room_state_of_json json with
  | Error msg -> Alcotest.fail ("missing event_seq should default to 0: " ^ msg)
  | Ok decoded -> check_int "event_seq defaults to 0" 0 decoded.event_seq

let test_room_state_of_json_malformed () =
  let json = `String "not an object" in
  match CE.room_state_of_json json with
  | Ok _ -> Alcotest.fail "malformed json should not parse to room_state"
  | Error _ -> ()

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Coord_eio_pure"
    [
      ( "key_formatters",
        [
          Alcotest.test_case "agent_key"            `Quick test_agent_key;
          Alcotest.test_case "message_key zero-pad" `Quick test_message_key_zero_pads;
          Alcotest.test_case "message_key large"    `Quick test_message_key_large;
          Alcotest.test_case "lock_key"             `Quick test_lock_key;
          Alcotest.test_case "event_key zero-pad"   `Quick test_event_key_zero_pads;
        ] );
      ( "event_type_to_string",
        [
          Alcotest.test_case "all variants" `Quick test_event_type_strings;
        ] );
      ( "room_state_round_trip",
        [
          Alcotest.test_case "default state"               `Quick
            test_default_room_state_round_trip;
          Alcotest.test_case "paused state with all opts"  `Quick
            test_paused_room_state_round_trip;
          Alcotest.test_case "missing event_seq defaults"  `Quick
            test_room_state_of_json_missing_event_seq;
          Alcotest.test_case "malformed json fails cleanly" `Quick
            test_room_state_of_json_malformed;
        ] );
    ]
