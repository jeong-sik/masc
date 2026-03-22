(** Tests for Room_checkpoint — snapshot and restore *)

module C = Room_checkpoint

let sample_state = `Assoc [
  ("mode", `String "normal");
  ("paused", `Bool false);
  ("active_agents", `List [`String "alice"; `String "bob"]);
]

let sample_tasks = `List [
  `Assoc [("id", `String "t1"); ("status", `String "in_progress")];
  `Assoc [("id", `String "t2"); ("status", `String "pending")];
]

let sample_agents = `List [
  `Assoc [("name", `String "alice"); ("joined", `Bool true)];
]

let test_capture_and_extract () =
  let cp = C.capture ~room_state:sample_state
    ~tasks:sample_tasks ~agents:sample_agents in
  Alcotest.(check bool) "timestamp > 0" true (C.timestamp cp > 0.0);
  Alcotest.(check bool) "room_state present" true
    (Option.is_some (C.room_state cp));
  Alcotest.(check bool) "tasks present" true
    (Option.is_some (C.tasks cp));
  Alcotest.(check bool) "agents present" true
    (Option.is_some (C.agents cp));
  (* Verify extracted values match *)
  (match C.room_state cp with
   | Some (`Assoc fields) ->
     Alcotest.(check bool) "mode field" true
       (List.exists (fun (k, _) -> k = "mode") fields)
   | _ -> Alcotest.fail "expected Assoc for room_state")

let test_serialization_roundtrip () =
  let cp = C.capture ~room_state:sample_state
    ~tasks:sample_tasks ~agents:sample_agents in
  let serialized = C.to_string cp in
  match C.of_string serialized with
  | Some restored ->
    Alcotest.(check bool) "timestamp preserved" true
      (Float.equal (C.timestamp cp) (C.timestamp restored));
    (* room_state should match *)
    Alcotest.(check bool) "room_state matches" true
      (Yojson.Safe.equal
         (Option.get (C.room_state cp))
         (Option.get (C.room_state restored)))
  | None -> Alcotest.fail "deserialization failed"

let test_invalid_json () =
  Alcotest.(check bool) "garbage" true
    (Option.is_none (C.of_string "not json"));
  Alcotest.(check bool) "wrong version" true
    (Option.is_none (C.of_string {|{"version":99}|}));
  Alcotest.(check bool) "empty object" true
    (Option.is_none (C.of_string "{}"))

let test_diff_no_changes () =
  let cp = C.capture ~room_state:sample_state
    ~tasks:sample_tasks ~agents:sample_agents in
  let d = C.diff cp cp in
  match d with
  | `Assoc fields ->
    Alcotest.(check int) "no changes" 0 (List.length fields)
  | _ -> Alcotest.fail "expected Assoc"

let test_diff_detects_changes () =
  let cp1 = C.capture ~room_state:sample_state
    ~tasks:sample_tasks ~agents:sample_agents in
  let modified_state = `Assoc [
    ("mode", `String "paused");
    ("paused", `Bool true);
    ("active_agents", `List [`String "alice"]);
  ] in
  let cp2 = C.capture ~room_state:modified_state
    ~tasks:sample_tasks ~agents:sample_agents in
  let d = C.diff cp1 cp2 in
  match d with
  | `Assoc fields ->
    (* room_state changed; timestamp may or may not differ depending on timing *)
    Alcotest.(check bool) "room_state changed" true
      (List.exists (fun (k, _) -> k = "room_state") fields);
    Alcotest.(check bool) "at least 1 change" true
      (List.length fields >= 1)
  | _ -> Alcotest.fail "expected Assoc"

let test_checkpoint_restore_cycle () =
  (* Simulate: checkpoint → modify → restore → verify *)
  let cp = C.capture ~room_state:sample_state
    ~tasks:sample_tasks ~agents:sample_agents in
  (* Serialize and deserialize (simulating storage) *)
  let stored = C.to_string cp in
  let restored = C.of_string stored in
  match restored with
  | Some rcp ->
    let rs = C.room_state rcp in
    let ts = C.tasks rcp in
    let ag = C.agents rcp in
    Alcotest.(check bool) "state matches" true
      (Yojson.Safe.equal (Option.get rs) sample_state);
    Alcotest.(check bool) "tasks match" true
      (Yojson.Safe.equal (Option.get ts) sample_tasks);
    Alcotest.(check bool) "agents match" true
      (Yojson.Safe.equal (Option.get ag) sample_agents)
  | None -> Alcotest.fail "restore failed"

let () =
  Alcotest.run "Room_checkpoint" [
    "capture", [
      Alcotest.test_case "extract fields" `Quick test_capture_and_extract;
    ];
    "serialization", [
      Alcotest.test_case "roundtrip" `Quick test_serialization_roundtrip;
      Alcotest.test_case "invalid input" `Quick test_invalid_json;
    ];
    "diff", [
      Alcotest.test_case "no changes" `Quick test_diff_no_changes;
      Alcotest.test_case "detects changes" `Quick test_diff_detects_changes;
    ];
    "restore", [
      Alcotest.test_case "full cycle" `Quick test_checkpoint_restore_cycle;
    ];
  ]
