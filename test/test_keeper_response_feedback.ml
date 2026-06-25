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

(* ── durable sink + read_tally (Stdlib I/O; default_config needs no Eio) ── *)

let with_tmp_config f =
  let tmp = Filename.temp_dir "krf_test" "" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote tmp))))
    (fun () -> f (Masc.Workspace.default_config tmp))

let ok_exn = function Ok x -> x | Error (`Io m) -> failwith ("unexpected `Io: " ^ m)

let test_sink_roundtrip () =
  with_tmp_config (fun config ->
    let put turn_id signal recorded_at =
      ok_exn (F.record ~config (mk ~keeper_id:"k1" ~turn_id ~signal ~recorded_at ()))
    in
    put "t1" F.Helpful 1.0;
    put "t2" F.Helpful 2.0;
    put "t3" F.Not_helpful 3.0;
    put "t1" F.Cleared 4.0;
    (* re-read from disk *)
    let t = ok_exn (F.read_tally ~config ~keeper_id:"k1") in
    check "sink helpful=1 (t1 cleared, t2 helpful)" (t.F.helpful = 1);
    check "sink not_helpful=1" (t.F.not_helpful = 1);
    check "sink cleared=1 (t1 latest)" (t.F.cleared = 1);
    check "sink net=0" (t.F.net = 0);
    check "sink malformed=0" (t.F.malformed = 0);
    check "sink last_at=4.0" (t.F.last_at = Some 4.0))

let test_read_missing_log_is_empty () =
  with_tmp_config (fun config ->
    let t = ok_exn (F.read_tally ~config ~keeper_id:"never-voted") in
    check "missing log -> empty tally" (t = F.empty_tally))

let test_malformed_counted_not_fatal () =
  with_tmp_config (fun config ->
    ok_exn (F.record ~config (mk ~keeper_id:"k2" ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()));
    (* a non-JSON line and a valid-JSON-but-not-a-record line, appended raw *)
    let path = Masc.Keeper_types_support.keeper_feedback_log_path config "k2" in
    let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
    output_string oc "this is not json\n";
    output_string oc "{\"foo\":1}\n";
    close_out oc;
    ok_exn (F.record ~config (mk ~keeper_id:"k2" ~turn_id:"t2" ~signal:F.Not_helpful ~recorded_at:2.0 ()));
    let t = ok_exn (F.read_tally ~config ~keeper_id:"k2") in
    (* valid votes survive; the two bad lines are counted, not zeroing the tally *)
    check "malformed: helpful=1" (t.F.helpful = 1);
    check "malformed: not_helpful=1" (t.F.not_helpful = 1);
    check "malformed: count=2 (non-json + non-record)" (t.F.malformed = 2))

(* ── HTTP wire helpers (tally_to_json / record_of_request_body) ───────── *)

let member k = function `Assoc fs -> List.assoc_opt k fs | _ -> None

let test_tally_to_json () =
  let t =
    F.tally_of_records
      [ mk ~turn_id:"t1" ~signal:F.Helpful ~recorded_at:1.0 ()
      ; mk ~turn_id:"t2" ~signal:F.Not_helpful ~recorded_at:2.0 ()
      ]
  in
  let j = F.tally_to_json t in
  check "json helpful" (member "helpful" j = Some (`Int 1));
  check "json not_helpful" (member "not_helpful" j = Some (`Int 1));
  check "json net" (member "net" j = Some (`Int 0));
  check "json malformed" (member "malformed" j = Some (`Int 0));
  check "json last_at" (member "last_at" j = Some (`Float 2.0));
  (* empty tally -> last_at null *)
  check "empty last_at null" (member "last_at" (F.tally_to_json F.empty_tally) = Some `Null)

let body signal source turn_id =
  `Assoc
    [ ("signal", `String signal); ("source", `String source); ("turn_id", `String turn_id) ]

let test_record_of_request_body () =
  (match F.record_of_request_body ~keeper_id:"k1" ~recorded_at:7.0 (body "up" "dashboard" "t9") with
   | Ok r ->
     check "parsed keeper_id from path" (r.F.keeper_id = "k1");
     check "parsed recorded_at from clock" (r.F.recorded_at = 7.0);
     check "parsed signal" (r.F.signal = F.Helpful);
     check "parsed turn_id" (r.F.turn_id = "t9")
   | Error e -> failwith ("expected Ok, got: " ^ e));
  check "unknown signal -> Error"
    (Result.is_error (F.record_of_request_body ~keeper_id:"k" ~recorded_at:0. (body "love" "dashboard" "t")));
  check "unknown source -> Error"
    (Result.is_error (F.record_of_request_body ~keeper_id:"k" ~recorded_at:0. (body "up" "discord" "t")));
  check "blank turn_id -> Error"
    (Result.is_error (F.record_of_request_body ~keeper_id:"k" ~recorded_at:0. (body "up" "dashboard" "  ")));
  check "missing field -> Error"
    (Result.is_error (F.record_of_request_body ~keeper_id:"k" ~recorded_at:0. (`Assoc [ ("signal", `String "up") ])));
  check "non-object -> Error"
    (Result.is_error (F.record_of_request_body ~keeper_id:"k" ~recorded_at:0. (`String "x")))

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
  test_sink_roundtrip ();
  test_read_missing_log_is_empty ();
  test_malformed_counted_not_fatal ();
  test_tally_to_json ();
  test_record_of_request_body ();
  print_endline "test_keeper_response_feedback: OK"
