(** Phase 1a tests for {!Keeper_response_feedback}: the pure typed model,
    strict codec, and deterministic tally. No I/O. *)

module F = Masc.Keeper_response_feedback

let check name cond = if not cond then failwith ("FAIL: " ^ name)

let mk ?(keeper_id = "k") ~turn_id ~signal ?(source = F.Dashboard) ~recorded_at () : F.record =
  { F.keeper_id; turn_id; signal; source; recorded_at }

(* ── wire codec ──────────────────────────────────────────────────────── *)

let test_signal_wire_roundtrip () =
  List.iter
    (fun s -> check "signal roundtrip" (F.signal_of_wire (F.signal_to_wire s) = Ok s))
    [ F.Helpful; F.Not_helpful; F.Cleared ];
  check "source roundtrip" (F.source_of_wire (F.source_to_wire F.Dashboard) = Ok F.Dashboard)

let test_signal_unknown_is_error () =
  check "unknown signal -> Error" (Result.is_error (F.signal_of_wire "thumbsup"));
  check "unknown source -> Error" (Result.is_error (F.source_of_wire "discord"));
  (* no Unknown->default: empty string is also an error, never a fallback *)
  check "empty signal -> Error" (Result.is_error (F.signal_of_wire ""))

let test_json_roundtrip () =
  let r = mk ~turn_id:"masc-improver:42" ~signal:F.Not_helpful ~recorded_at:1718000000.5 () in
  check "json roundtrip" (F.of_json (F.to_json r) = Ok r)

let test_json_strict () =
  check "non-object -> Error" (Result.is_error (F.of_json (`String "x")));
  check "missing field -> Error"
    (Result.is_error (F.of_json (`Assoc [ ("keeper_id", `String "k") ])));
  check "unknown signal token -> Error"
    (Result.is_error
       (F.of_json
          (`Assoc
            [ ("keeper_id", `String "k")
            ; ("turn_id", `String "t1")
            ; ("signal", `String "love")
            ; ("source", `String "dashboard")
            ; ("recorded_at", `Float 1.0)
            ])));
  (* recorded_at accepts Int (JSON has no float/int distinction at the wire) *)
  check "int recorded_at -> Ok"
    (Result.is_ok
       (F.of_json
          (`Assoc
            [ ("keeper_id", `String "k")
            ; ("turn_id", `String "t1")
            ; ("signal", `String "up")
            ; ("source", `String "dashboard")
            ; ("recorded_at", `Int 1718000000)
            ])))

(* ── tally ───────────────────────────────────────────────────────────── *)

let test_tally_basic () =
  let t =
    F.tally_of_records
      [ mk ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()
      ; mk ~turn_id:"t2" ~signal:F.Helpful ~recorded_at:2.0 ()
      ; mk ~turn_id:"t3" ~signal:F.Not_helpful ~recorded_at:3.0 ()
      ]
  in
  check "helpful=2" (t.F.helpful = 2);
  check "not_helpful=1" (t.F.not_helpful = 1);
  check "net=1" (t.F.net = 1);
  check "malformed=0 (pure records)" (t.F.malformed = 0);
  check "last_at=3.0" (t.F.last_at = Some 3.0)

let test_tally_dedup_last_wins () =
  (* same turn voted Helpful then re-voted Not_helpful: latest (last in the
     chronological list) wins, so it counts once as not_helpful. *)
  let t =
    F.tally_of_records
      [ mk ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()
      ; mk ~turn_id:"t1" ~signal:F.Not_helpful ~recorded_at:2.0 ()
      ]
  in
  check "dedup helpful=0" (t.F.helpful = 0);
  check "dedup not_helpful=1" (t.F.not_helpful = 1);
  check "dedup net=-1" (t.F.net = -1);
  check "dedup last_at=2.0" (t.F.last_at = Some 2.0)

let test_tally_cleared_excluded_from_net () =
  let t =
    F.tally_of_records
      [ mk ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()
      ; mk ~turn_id:"t2" ~signal:F.Cleared ~recorded_at:2.0 ()
      ]
  in
  check "cleared counted" (t.F.cleared = 1);
  check "cleared not in net" (t.F.net = 1)

let test_tally_retraction_supersedes () =
  (* Helpful then Cleared on the same turn: net opinion is now "no opinion". *)
  let t =
    F.tally_of_records
      [ mk ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()
      ; mk ~turn_id:"t1" ~signal:F.Cleared ~recorded_at:2.0 ()
      ]
  in
  check "retraction: helpful=0" (t.F.helpful = 0);
  check "retraction: cleared=1" (t.F.cleared = 1);
  check "retraction: net=0" (t.F.net = 0)

let test_tally_deterministic () =
  let recs =
    [ mk ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()
    ; mk ~turn_id:"t2" ~signal:F.Not_helpful ~recorded_at:2.0 ()
    ; mk ~turn_id:"t1" ~signal:F.Cleared ~recorded_at:3.0 ()
    ]
  in
  check "same input -> same tally" (F.tally_of_records recs = F.tally_of_records recs);
  check "empty tally" (F.tally_of_records [] = F.empty_tally)

let () =
  test_signal_wire_roundtrip ();
  test_signal_unknown_is_error ();
  test_json_roundtrip ();
  test_json_strict ();
  test_tally_basic ();
  test_tally_dedup_last_wins ();
  test_tally_cleared_excluded_from_net ();
  test_tally_retraction_supersedes ();
  test_tally_deterministic ();
  print_endline "test_keeper_response_feedback: OK"
