(* Cycle 22 / Tier A4 tests — Autonomous_bridge cooperation contract,
   tick delegation, suspend/resume JSON round-trip.

   Validates:
   - [create] produces an Idle bridge via the running_valid witness
   - Accessors agree with the wrapped Autonomous_state
   - [tick] increments iteration_count + advances last_tick_at and
     wraps Autonomous_state.tick's FullSuccess unchanged in shape
   - [suspend] emits the v0 schema
   - [resume] round-trips iteration_count + timestamps from suspend
   - [resume] rejects wrong [kind] and missing fields *)

module B = Autonomous.Autonomous_bridge
module S = Autonomous.Autonomous_state
module P = Autonomous.Autonomous_phase
module Outcome = Shared_types.Resilience_outcome

let witness () = B.Witness.running_witness

let test_create_idle () =
  let b = B.create (witness ()) ~now:1000.0 () in
  assert (B.current_phase_string b = "idle");
  assert (B.current_phase b = P.Tag_idle);
  assert (B.iteration_count b = 0);
  assert (B.created_at b = 1000.0);
  assert (B.last_tick_at b = 1000.0)

let test_create_with_meta () =
  let meta = `Assoc [ ("scope", `String "smoke") ] in
  let b = B.create (witness ()) ~meta ~now:0.0 () in
  let json = B.suspend b in
  let state_json = Yojson.Safe.Util.member "state" json in
  let ctx = Yojson.Safe.Util.member "ctx" state_json in
  assert (Yojson.Safe.Util.member "meta" ctx = meta)

let test_current_state_matches_wrapped () =
  let b = B.create (witness ()) ~now:1000.0 () in
  let s = B.current_state b in
  assert (S.current_phase_string s = B.current_phase_string b);
  assert (S.iteration_count s = 0);
  (* Bridge bookkeeping is independent of Autonomous_state's
     iteration_count: bridge counts ticks; state could be
     advanced by other entry points in later Tiers. *)
  assert (S.last_tick_at s = B.last_tick_at b)

let test_tick_increments_and_advances () =
  let b = B.create (witness ()) ~now:1000.0 () in
  let outcome = B.tick b ~now:1500.0 in
  match outcome with
  | Outcome.FullSuccess { value = b'; _ } ->
      assert (B.iteration_count b' = 1);
      assert (B.last_tick_at b' = 1500.0);
      assert (B.created_at b' = 1000.0)
  | _ -> assert false

let test_tick_chain () =
  let b0 = B.create (witness ()) ~now:0.0 () in
  let b1 =
    match B.tick b0 ~now:1.0 with
    | Outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  let b2 =
    match B.tick b1 ~now:2.0 with
    | Outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  assert (B.iteration_count b2 = 2);
  assert (B.last_tick_at b2 = 2.0);
  assert (B.created_at b2 = 0.0)

let test_suspend_schema () =
  let b = B.create (witness ()) ~now:1000.0 () in
  let json = B.suspend b in
  assert (Yojson.Safe.Util.member "kind" json = `String "autonomous_bridge.v0");
  assert (Yojson.Safe.Util.member "iteration_count" json = `Int 0);
  assert (Yojson.Safe.Util.member "created_at" json = `Float 1000.0);
  assert (Yojson.Safe.Util.member "last_tick_at" json = `Float 1000.0);
  assert (
    Yojson.Safe.Util.member "state" json
    |> Yojson.Safe.Util.member "phase"
    = `String "idle")

let test_resume_round_trip () =
  let b = B.create (witness ()) ~now:100.0 () in
  let b' =
    match B.tick b ~now:200.0 with
    | Outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  let json = B.suspend b' in
  match B.resume (witness ()) json ~now:300.0 with
  | Ok restored ->
      assert (B.iteration_count restored = 1);
      assert (B.created_at restored = 100.0);
      assert (B.last_tick_at restored = 200.0);
      assert (B.current_phase_string restored = "idle")
  | Error e -> failwith ("unexpected resume error: " ^ e)

let test_resume_rejects_wrong_kind () =
  let bad =
    `Assoc
      [ ("kind", `String "something_else");
        ("iteration_count", `Int 0);
        ("created_at", `Float 0.0);
        ("last_tick_at", `Float 0.0);
        ("state", `Assoc []);
      ]
  in
  match B.resume (witness ()) bad ~now:0.0 with
  | Ok _ -> assert false
  | Error msg -> assert (String.length msg > 0)

let test_resume_rejects_missing_field () =
  let bad =
    `Assoc
      [ ("kind", `String "autonomous_bridge.v0");
        ("iteration_count", `Int 0);
        (* created_at deliberately missing *)
        ("last_tick_at", `Float 0.0);
        ("state", `Assoc []);
      ]
  in
  match B.resume (witness ()) bad ~now:0.0 with
  | Ok _ -> assert false
  | Error _ -> ()

let () =
  test_create_idle ();
  test_create_with_meta ();
  test_current_state_matches_wrapped ();
  test_tick_increments_and_advances ();
  test_tick_chain ();
  test_suspend_schema ();
  test_resume_round_trip ();
  test_resume_rejects_wrong_kind ();
  test_resume_rejects_missing_field ();
  print_endline "test_autonomous_bridge: all assertions passed"
