(* Cycle 22 / Tier A5 tests — keeper post-turn autonomous wire-in.

   Validates the helper surface exposed for the wire-in:
   - [masc_autonomous_enabled] reads the [MASC_AUTONOMOUS] env var
     and returns true only for ["1" | "true" | "yes" | "on"].
   - [upsert_autonomous_meta] preserves existing working_context
     keys when adding the ["autonomous_meta"] sub-tree, and replaces
     a prior ["autonomous_meta"] entry without duplicating it.

   The full apply_post_turn_lifecycle integration is observed by an
   e2e test in lib/keeper's existing harness; this suite covers the
   wire-in's storage discipline and the env-flag predicate directly. *)

module Wirein = Autonomous.Wirein_helpers

(* ─── masc_autonomous_enabled env predicate ───────────────────── *)

let test_flag_unset_is_off () =
  Unix.putenv "MASC_AUTONOMOUS" "";
  assert (Wirein.masc_autonomous_enabled () = false);
  (* Empty value is not in the truthy set. *)
  ()

let test_flag_truthy_values () =
  let truthy = [ "1"; "true"; "yes"; "on" ] in
  List.iter
    (fun v ->
      Unix.putenv "MASC_AUTONOMOUS" v;
      let ok = Wirein.masc_autonomous_enabled () in
      assert ok)
    truthy

let test_flag_falsy_values () =
  let falsy = [ "0"; "false"; "no"; "off"; "FALSE"; "TRUE" (* case-sensitive *) ] in
  List.iter
    (fun v ->
      Unix.putenv "MASC_AUTONOMOUS" v;
      let off = not (Wirein.masc_autonomous_enabled ()) in
      assert off)
    falsy;
  (* Reset for downstream tests. *)
  Unix.putenv "MASC_AUTONOMOUS" ""

(* ─── upsert_autonomous_meta storage discipline ───────────────── *)

let sample_meta : Yojson.Safe.t =
  `Assoc
    [ ("kind", `String "autonomous_bridge.v0");
      ("iteration_count", `Int 1);
      ("created_at", `Float 1000.0);
      ("last_tick_at", `Float 2000.0);
    ]

let test_upsert_into_none_creates_assoc () =
  let result = Wirein.upsert_autonomous_meta None sample_meta in
  match result with
  | Some (`Assoc kv) -> (
      assert (List.length kv = 1);
      match List.assoc_opt "autonomous_meta" kv with
      | Some v -> assert (v = sample_meta)
      | None -> assert false)
  | _ -> assert false

let test_upsert_preserves_existing_keys () =
  let prior =
    `Assoc
      [ ("turn_count", `Int 5);
        ("custom_data", `String "preserved");
      ]
  in
  let result = Wirein.upsert_autonomous_meta (Some prior) sample_meta in
  match result with
  | Some (`Assoc kv) ->
      (* Both prior keys preserved + autonomous_meta added. *)
      assert (List.assoc_opt "turn_count" kv = Some (`Int 5));
      assert (List.assoc_opt "custom_data" kv = Some (`String "preserved"));
      assert (List.assoc_opt "autonomous_meta" kv = Some sample_meta)
  | _ -> assert false

let test_upsert_replaces_prior_autonomous_meta () =
  let stale =
    `Assoc
      [ ("autonomous_meta", `String "old_payload");
        ("turn_count", `Int 3);
      ]
  in
  let result = Wirein.upsert_autonomous_meta (Some stale) sample_meta in
  match result with
  | Some (`Assoc kv) ->
      (* No duplicate keys + new value wins. *)
      let count =
        List.fold_left
          (fun n (k, _) -> if k = "autonomous_meta" then n + 1 else n)
          0 kv
      in
      assert (count = 1);
      assert (List.assoc_opt "autonomous_meta" kv = Some sample_meta);
      assert (List.assoc_opt "turn_count" kv = Some (`Int 3))
  | _ -> assert false

let test_upsert_wraps_non_assoc_input () =
  (* Conservative behaviour: replace a non-Assoc working_context with
     an Assoc carrying autonomous_meta — do not silently overwrite the
     prior payload, but do guarantee a usable shape downstream. *)
  let weird : Yojson.Safe.t = `String "scalar_payload" in
  let result = Wirein.upsert_autonomous_meta (Some weird) sample_meta in
  match result with
  | Some (`Assoc kv) ->
      assert (List.assoc_opt "autonomous_meta" kv = Some sample_meta)
  | _ -> assert false

(* ─── Round-trip via Autonomous_bridge.suspend → upsert → Autonomous_bridge.resume ── *)

let test_round_trip_with_autonomous_bridge () =
  let module B = Autonomous.Autonomous_bridge in
  let witness = B.Witness.running_witness in
  let bridge = B.create witness ~now:1000.0 () in
  let advanced =
    match B.tick bridge ~now:2000.0 with
    | Shared_types.Resilience_outcome.FullSuccess { value; _ } -> value
    | _ -> assert false
  in
  let suspended = B.suspend advanced in
  let wc = Wirein.upsert_autonomous_meta None suspended in
  let stored_meta =
    match wc with
    | Some (`Assoc kv) -> List.assoc "autonomous_meta" kv
    | _ -> assert false
  in
  match B.resume witness stored_meta ~now:3000.0 with
  | Ok restored ->
      assert (B.iteration_count restored = 1);
      assert (B.created_at restored = 1000.0);
      assert (B.last_tick_at restored = 2000.0)
  | Error e -> failwith ("round-trip resume failed: " ^ e)

let () =
  test_flag_unset_is_off ();
  test_flag_truthy_values ();
  test_flag_falsy_values ();
  test_upsert_into_none_creates_assoc ();
  test_upsert_preserves_existing_keys ();
  test_upsert_replaces_prior_autonomous_meta ();
  test_upsert_wraps_non_assoc_input ();
  test_round_trip_with_autonomous_bridge ();
  print_endline "test_autonomous_wirein: all assertions passed"
