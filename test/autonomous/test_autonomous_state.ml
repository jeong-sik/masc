(* Cycle 21 / Tier B4 tests — Autonomous_state initial Idle state,
   tick stub, and JSON projection.

   Validates:
   - [init] produces an Idle phase with iteration_count = 0
   - [current_phase] / [current_phase_string] reflect the packed any
   - [tick] returns FullSuccess with iteration_count incremented and
     last_tick_at advanced
   - [tick]'s value preserves [created_at]
   - [to_json] keys + Idle_ctx [meta] passthrough
   - Default [meta] is [`Null]
   - Custom [meta] is round-tripped via JSON *)

module S = Autonomous.Autonomous_state
module P = Autonomous.Autonomous_phase
module Outcome = Shared_types.Resilience_outcome
module Confidence = Shared_types.Confidence

let test_init_creates_idle () =
  let s = S.init ~now:1000.0 () in
  assert (S.current_phase_string s = "idle");
  assert (S.current_phase s = P.Tag_idle);
  assert (S.iteration_count s = 0);
  assert (S.last_tick_at s = 1000.0);
  assert (S.created_at s = 1000.0)

let test_init_default_meta_null () =
  let s = S.init ~now:0.0 () in
  let json = S.to_json s in
  let ctx = Yojson.Safe.Util.member "ctx" json in
  let meta = Yojson.Safe.Util.member "meta" ctx in
  assert (meta = `Null)

let test_init_custom_meta_passthrough () =
  let meta = `Assoc [ ("role", `String "analyst"); ("budget", `Int 100) ] in
  let s = S.init ~meta ~now:0.0 () in
  let json = S.to_json s in
  let ctx = Yojson.Safe.Util.member "ctx" json in
  let meta_back = Yojson.Safe.Util.member "meta" ctx in
  assert (meta_back = meta)

let test_tick_returns_full_success () =
  let s = S.init ~now:1000.0 () in
  let outcome = S.tick s ~now:1500.0 in
  match outcome with
  | Outcome.FullSuccess { value; confidence; artifacts } ->
      assert (S.last_tick_at value = 1500.0);
      assert (S.iteration_count value = 1);
      assert (S.created_at value = 1000.0);
      assert (Confidence.to_float confidence = 1.0);
      assert (artifacts = [])
  | Outcome.PartialSuccess _ -> assert false
  | Outcome.GracefulFailure _ -> assert false

let test_tick_chain_increments () =
  let s0 = S.init ~now:0.0 () in
  let s1 =
    match S.tick s0 ~now:1.0 with
    | Outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  let s2 =
    match S.tick s1 ~now:2.0 with
    | Outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  assert (S.iteration_count s2 = 2);
  assert (S.last_tick_at s2 = 2.0);
  assert (S.created_at s2 = 0.0)

let test_to_json_shape () =
  let s = S.init ~now:1000.0 () in
  let json = S.to_json s in
  let assoc = Yojson.Safe.Util.to_assoc json in
  let keys = List.map fst assoc in
  assert (List.mem "phase" keys);
  assert (List.mem "iteration_count" keys);
  assert (List.mem "created_at" keys);
  assert (List.mem "last_tick_at" keys);
  assert (List.mem "ctx" keys);
  assert (Yojson.Safe.Util.member "phase" json = `String "idle");
  assert (Yojson.Safe.Util.member "iteration_count" json = `Int 0)

let test_to_json_phase_after_tick () =
  let s = S.init ~now:0.0 () in
  let s' =
    match S.tick s ~now:1.0 with
    | Outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  let json = S.to_json s' in
  (* Tick is a stub — phase remains Idle until A4 wires real transitions. *)
  assert (Yojson.Safe.Util.member "phase" json = `String "idle");
  assert (Yojson.Safe.Util.member "iteration_count" json = `Int 1);
  assert (Yojson.Safe.Util.member "last_tick_at" json = `Float 1.0)

let () =
  test_init_creates_idle ();
  test_init_default_meta_null ();
  test_init_custom_meta_passthrough ();
  test_tick_returns_full_success ();
  test_tick_chain_increments ();
  test_to_json_shape ();
  test_to_json_phase_after_tick ();
  print_endline "test_autonomous_state: all assertions passed"
