(* Cycle 23 / Tier B6 tests — Stimulus value type.

   Validates:
   - [source]-level [@@deriving tla] correctness
   - [source_to_string] / [source_of_string] round-trip
   - [make] accepts [salience] in [0.0, 1.0]
   - [make] rejects out-of-range, NaN, and empty id (Invalid_argument)
   - [score] = salience at [now = timestamp]
   - [score] decays for [now > timestamp]
   - [score] does not amplify for [now < timestamp]
   - [to_json] / [of_json] symmetric round-trip
   - [of_json] rejects malformed inputs with Error *)

module S = Autonomous.Stimulus

(* ─── Source taxonomy + tla deriver ───────────────────────────── *)

let test_source_to_tla_symbol () =
  assert (S.to_tla_symbol S.User_message = "user_message");
  assert (S.to_tla_symbol S.Memory_recall = "memory_recall");
  assert (S.to_tla_symbol S.Discovery_signal = "discovery_signal");
  assert (S.to_tla_symbol S.Resource_alert = "resource_alert");
  assert (S.to_tla_symbol S.Goal_phase_change = "goal_phase_change");
  assert (S.to_tla_symbol S.Priority_shift = "priority_shift");
  assert (S.to_tla_symbol S.External_event = "external_event")

let test_all_symbols_count () = assert (List.length S.all_symbols = 7)

let test_all_states_count () = assert (List.length S.all_states = 7)

let test_source_of_string_round_trip () =
  let all =
    [
      S.User_message;
      S.Memory_recall;
      S.Discovery_signal;
      S.Resource_alert;
      S.Goal_phase_change;
      S.Priority_shift;
      S.External_event;
    ]
  in
  List.iter
    (fun src ->
      let s = S.source_to_string src in
      match S.source_of_string s with
      | Some src' -> assert (src' = src)
      | None -> assert false)
    all

let test_source_of_string_unknown_is_none () =
  assert (S.source_of_string "" = None);
  assert (S.source_of_string "USER_MESSAGE" = None);
  assert (S.source_of_string "user-message" = None);
  assert (S.source_of_string "nope" = None)

(* ─── make: range validation ──────────────────────────────────── *)

let test_make_valid_mid () =
  let s =
    S.make
      ~id:"stim-1"
      ~source:S.User_message
      ~payload:`Null
      ~salience:0.5
      ~timestamp:1000.0
  in
  assert (s.id = "stim-1");
  assert (s.source = S.User_message);
  assert (s.salience = 0.5);
  assert (s.timestamp = 1000.0)

let test_make_valid_boundaries () =
  let s0 =
    S.make ~id:"a" ~source:S.User_message ~payload:`Null
      ~salience:0.0 ~timestamp:0.0
  in
  let s1 =
    S.make ~id:"b" ~source:S.User_message ~payload:`Null
      ~salience:1.0 ~timestamp:0.0
  in
  assert (s0.salience = 0.0);
  assert (s1.salience = 1.0)

let raises_invalid_argument f =
  try
    let _ = f () in
    false
  with Invalid_argument _ -> true

let test_make_rejects_above_one () =
  assert (
    raises_invalid_argument (fun () ->
        S.make ~id:"x" ~source:S.User_message ~payload:`Null
          ~salience:2.0 ~timestamp:0.0))

let test_make_rejects_negative () =
  assert (
    raises_invalid_argument (fun () ->
        S.make ~id:"x" ~source:S.User_message ~payload:`Null
          ~salience:(-0.001) ~timestamp:0.0))

let test_make_rejects_nan () =
  assert (
    raises_invalid_argument (fun () ->
        S.make ~id:"x" ~source:S.User_message ~payload:`Null
          ~salience:Float.nan ~timestamp:0.0))

let test_make_rejects_infinity () =
  assert (
    raises_invalid_argument (fun () ->
        S.make ~id:"x" ~source:S.User_message ~payload:`Null
          ~salience:Float.infinity ~timestamp:0.0))

let test_make_rejects_empty_id () =
  assert (
    raises_invalid_argument (fun () ->
        S.make ~id:"" ~source:S.User_message ~payload:`Null
          ~salience:0.5 ~timestamp:0.0))

(* ─── score: decay semantics ──────────────────────────────────── *)

let approx_eq a b = Float.abs (a -. b) < 1e-9

let test_score_at_emit_time () =
  let s =
    S.make ~id:"x" ~source:S.User_message ~payload:`Null
      ~salience:0.7 ~timestamp:1000.0
  in
  assert (approx_eq (S.score s ~now:1000.0) 0.7)

let test_score_decays_over_time () =
  let s =
    S.make ~id:"x" ~source:S.User_message ~payload:`Null
      ~salience:1.0 ~timestamp:0.0
  in
  let s100 = S.score s ~now:100.0 in
  let s500 = S.score s ~now:500.0 in
  assert (s100 < 1.0);
  assert (s500 < s100);
  (* salience=1.0, decay=0.01, age=100 → exp(-1.0) ≈ 0.3679 *)
  assert (approx_eq s100 (Float.exp (-1.0)))

let test_score_clamps_negative_age () =
  let s =
    S.make ~id:"x" ~source:S.User_message ~payload:`Null
      ~salience:0.5 ~timestamp:1000.0
  in
  (* now < timestamp must NOT amplify above salience *)
  assert (approx_eq (S.score s ~now:500.0) 0.5)

(* ─── JSON round-trip ─────────────────────────────────────────── *)

let test_to_json_shape () =
  let s =
    S.make ~id:"abc" ~source:S.Memory_recall
      ~payload:(`Assoc [ ("k", `Int 1) ])
      ~salience:0.3 ~timestamp:42.0
  in
  let j = S.to_json s in
  assert (Yojson.Safe.Util.member "id" j = `String "abc");
  assert (Yojson.Safe.Util.member "source" j = `String "memory_recall");
  assert (
    Yojson.Safe.Util.member "payload" j = `Assoc [ ("k", `Int 1) ]);
  assert (Yojson.Safe.Util.member "salience" j = `Float 0.3);
  assert (Yojson.Safe.Util.member "timestamp" j = `Float 42.0)

let test_of_json_round_trip () =
  let s =
    S.make ~id:"abc" ~source:S.External_event
      ~payload:(`String "hello") ~salience:0.9 ~timestamp:7.0
  in
  let j = S.to_json s in
  match S.of_json j with
  | Ok s' ->
      assert (s'.id = s.id);
      assert (s'.source = s.source);
      assert (s'.payload = s.payload);
      assert (approx_eq s'.salience s.salience);
      assert (approx_eq s'.timestamp s.timestamp)
  | Error e -> failwith ("of_json round-trip failed: " ^ e)

let test_of_json_int_salience_accepted () =
  (* Yojson may emit `Int for whole-number floats; of_json must accept both. *)
  let j =
    `Assoc
      [
        ("id", `String "x");
        ("source", `String "user_message");
        ("payload", `Null);
        ("salience", `Int 1);
        ("timestamp", `Int 0);
      ]
  in
  match S.of_json j with
  | Ok s ->
      assert (approx_eq s.salience 1.0);
      assert (approx_eq s.timestamp 0.0)
  | Error e -> failwith ("expected Ok, got Error: " ^ e)

let test_of_json_rejects_non_object () =
  match S.of_json (`String "nope") with
  | Ok _ -> assert false
  | Error _ -> ()

let test_of_json_rejects_missing_key () =
  let j =
    `Assoc
      [
        ("id", `String "x");
        ("source", `String "user_message");
        (* payload missing *)
        ("salience", `Float 0.5);
        ("timestamp", `Float 0.0);
      ]
  in
  match S.of_json j with Ok _ -> assert false | Error _ -> ()

let test_of_json_rejects_unknown_source () =
  let j =
    `Assoc
      [
        ("id", `String "x");
        ("source", `String "made_up");
        ("payload", `Null);
        ("salience", `Float 0.5);
        ("timestamp", `Float 0.0);
      ]
  in
  match S.of_json j with Ok _ -> assert false | Error _ -> ()

let test_of_json_rejects_out_of_range_salience () =
  let j =
    `Assoc
      [
        ("id", `String "x");
        ("source", `String "user_message");
        ("payload", `Null);
        ("salience", `Float 1.5);
        ("timestamp", `Float 0.0);
      ]
  in
  match S.of_json j with Ok _ -> assert false | Error _ -> ()

let () =
  test_source_to_tla_symbol ();
  test_all_symbols_count ();
  test_all_states_count ();
  test_source_of_string_round_trip ();
  test_source_of_string_unknown_is_none ();
  test_make_valid_mid ();
  test_make_valid_boundaries ();
  test_make_rejects_above_one ();
  test_make_rejects_negative ();
  test_make_rejects_nan ();
  test_make_rejects_infinity ();
  test_make_rejects_empty_id ();
  test_score_at_emit_time ();
  test_score_decays_over_time ();
  test_score_clamps_negative_age ();
  test_to_json_shape ();
  test_of_json_round_trip ();
  test_of_json_int_salience_accepted ();
  test_of_json_rejects_non_object ();
  test_of_json_rejects_missing_key ();
  test_of_json_rejects_unknown_source ();
  test_of_json_rejects_out_of_range_salience ();
  print_endline "test_autonomous_stimulus: all assertions passed"
