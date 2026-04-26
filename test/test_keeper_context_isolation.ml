(** Integration tests: multi-keeper context isolation.

    Verifies that when multiple keepers run concurrently (simulated),
    each keeper's OAS Context.t remains independent.

    Covers:
    - Two keepers with separate contexts never cross-contaminate
    - Checkpoint save/load preserves context identity
    - Compaction on one keeper doesn't affect another
    - Sub-agent scope from one keeper is invisible to the other *)

open Alcotest
module Ctx = Agent_sdk.Context

(* ── Helpers ─────────────────────────────────────── *)

let ctx_has_key ctx k =
  match Ctx.get ctx k with
  | Some _ -> true
  | None -> false
;;

let ctx_get_string ctx k =
  match Ctx.get ctx k with
  | Some (`String s) -> s
  | _ -> failwith ("expected string for key: " ^ k)
;;

(* ── Test: Basic Isolation ───────────────────────── *)

let test_basic_isolation () =
  (* Two keepers, each with their own context *)
  let ctx_dreamer = Ctx.create () in
  let ctx_coder = Ctx.create () in
  (* Each writes keeper-specific state *)
  Ctx.set ctx_dreamer "keeper" (`String "dreamer");
  Ctx.set ctx_dreamer "turn" (`Int 1);
  Ctx.set ctx_dreamer "secret" (`String "dreamer_only");
  Ctx.set ctx_coder "keeper" (`String "coder");
  Ctx.set ctx_coder "turn" (`Int 5);
  Ctx.set ctx_coder "work_item" (`String "PR-5677");
  (* Verify no cross-contamination *)
  check string "dreamer keeper" "dreamer" (ctx_get_string ctx_dreamer "keeper");
  check string "coder keeper" "coder" (ctx_get_string ctx_coder "keeper");
  check bool "dreamer has no work_item" false (ctx_has_key ctx_dreamer "work_item");
  check bool "coder has no secret" false (ctx_has_key ctx_coder "secret")
;;

(* ── Test: Checkpoint Roundtrip Isolation ─────────── *)

let test_checkpoint_roundtrip_isolation () =
  let ctx_a = Ctx.create () in
  let ctx_b = Ctx.create () in
  Ctx.set ctx_a "state" (`String "working");
  Ctx.set ctx_b "state" (`String "idle");
  (* Simulate checkpoint: serialize both *)
  let json_a = Ctx.to_json ctx_a in
  let json_b = Ctx.to_json ctx_b in
  (* Simulate resume: deserialize *)
  let restored_a = Ctx.of_json json_a in
  let restored_b = Ctx.of_json json_b in
  (* Mutate restored_a — should not affect restored_b *)
  Ctx.set restored_a "state" (`String "compacting");
  Ctx.set restored_a "new_key" (`String "from_a");
  check string "restored_b unchanged" "idle" (ctx_get_string restored_b "state");
  check bool "restored_b no new_key" false (ctx_has_key restored_b "new_key");
  (* Original contexts also unaffected *)
  check string "original_a unchanged" "working" (ctx_get_string ctx_a "state")
;;

(* ── Test: Copy-Based Resume Isolation ───────────── *)

let test_copy_resume_isolation () =
  (* Simulates Agent.resume path: Context.copy checkpoint.context *)
  let checkpoint_ctx = Ctx.create () in
  Ctx.set checkpoint_ctx "trace_id" (`String "abc-123");
  Ctx.set checkpoint_ctx "turn_count" (`Int 3);
  (* Two keepers resume from the same checkpoint *)
  let ctx_k1 = Ctx.copy checkpoint_ctx in
  let ctx_k2 = Ctx.copy checkpoint_ctx in
  (* Each modifies its own copy *)
  Ctx.set ctx_k1 "turn_count" (`Int 4);
  Ctx.set ctx_k1 "k1_only" (`String "data");
  Ctx.set ctx_k2 "turn_count" (`Int 10);
  Ctx.set ctx_k2 "k2_only" (`String "other");
  (* Verify independence *)
  check bool "k1 turn = 4" true (Ctx.get ctx_k1 "turn_count" = Some (`Int 4));
  check bool "k2 turn = 10" true (Ctx.get ctx_k2 "turn_count" = Some (`Int 10));
  check
    bool
    "checkpoint unchanged"
    true
    (Ctx.get checkpoint_ctx "turn_count" = Some (`Int 3));
  check bool "k1 no k2_only" false (ctx_has_key ctx_k1 "k2_only");
  check bool "k2 no k1_only" false (ctx_has_key ctx_k2 "k1_only")
;;

(* ── Test: Scope Isolation Between Keepers ───────── *)

let test_scope_isolation_cross_keeper () =
  let parent = Ctx.create () in
  Ctx.set parent "shared_config" (`String "base");
  (* Keeper A creates a scope for sub-agent delegation *)
  let scope_a =
    Ctx.create_scope
      ~parent
      ~propagate_down:[ "shared_config" ]
      ~propagate_up:[ "result_a" ]
  in
  (* Keeper B creates a separate scope *)
  let scope_b =
    Ctx.create_scope
      ~parent
      ~propagate_down:[ "shared_config" ]
      ~propagate_up:[ "result_b" ]
  in
  (* Both work in their scopes *)
  Ctx.set scope_a.local "internal_a" (`String "secret_a");
  Ctx.set scope_a.local "result_a" (`String "answer_a");
  Ctx.set scope_b.local "internal_b" (`String "secret_b");
  Ctx.set scope_b.local "result_b" (`String "answer_b");
  (* Verify scope locals don't see each other *)
  check bool "scope_a no internal_b" false (ctx_has_key scope_a.local "internal_b");
  check bool "scope_b no internal_a" false (ctx_has_key scope_b.local "internal_a");
  (* Merge back *)
  Ctx.merge_back scope_a;
  Ctx.merge_back scope_b;
  (* Parent should have only propagated results *)
  check
    bool
    "parent has result_a"
    true
    (Ctx.get parent "result_a" = Some (`String "answer_a"));
  check
    bool
    "parent has result_b"
    true
    (Ctx.get parent "result_b" = Some (`String "answer_b"));
  (* Internal keys must NOT leak to parent *)
  check bool "parent no internal_a" false (ctx_has_key parent "internal_a");
  check bool "parent no internal_b" false (ctx_has_key parent "internal_b")
;;

(* ── Test: Scoped Key Collision ──────────────────── *)

let test_scoped_key_collision () =
  (* Both keepers use the same key name but in different contexts *)
  let ctx_a = Ctx.create () in
  let ctx_b = Ctx.create () in
  Ctx.set_scoped ctx_a Ctx.Session "trace_id" (`String "trace-AAA");
  Ctx.set_scoped ctx_b Ctx.Session "trace_id" (`String "trace-BBB");
  Ctx.set_scoped ctx_a Ctx.User "name" (`String "Alice");
  Ctx.set_scoped ctx_b Ctx.User "name" (`String "Bob");
  (* Same key name, different contexts *)
  check
    bool
    "a session"
    true
    (Ctx.get_scoped ctx_a Ctx.Session "trace_id" = Some (`String "trace-AAA"));
  check
    bool
    "b session"
    true
    (Ctx.get_scoped ctx_b Ctx.Session "trace_id" = Some (`String "trace-BBB"));
  check bool "a user" true (Ctx.get_scoped ctx_a Ctx.User "name" = Some (`String "Alice"));
  check bool "b user" true (Ctx.get_scoped ctx_b Ctx.User "name" = Some (`String "Bob"))
;;

(* ── Test: Concurrent Scope Merge Order ──────────── *)

let test_merge_order_independence () =
  let parent = Ctx.create () in
  Ctx.set parent "base" (`Int 0);
  let scope1 =
    Ctx.create_scope ~parent ~propagate_down:[ "base" ] ~propagate_up:[ "r1" ]
  in
  let scope2 =
    Ctx.create_scope ~parent ~propagate_down:[ "base" ] ~propagate_up:[ "r2" ]
  in
  Ctx.set scope1.local "r1" (`Int 1);
  Ctx.set scope2.local "r2" (`Int 2);
  (* Merge in opposite order: 2 then 1 *)
  Ctx.merge_back scope2;
  Ctx.merge_back scope1;
  check bool "r1 present" true (Ctx.get parent "r1" = Some (`Int 1));
  check bool "r2 present" true (Ctx.get parent "r2" = Some (`Int 2));
  check bool "base unchanged" true (Ctx.get parent "base" = Some (`Int 0))
;;

(* ── Test: Diff Between Keeper Contexts ──────────── *)

let test_diff_cross_keeper () =
  let ctx_a = Ctx.create () in
  let ctx_b = Ctx.create () in
  Ctx.set ctx_a "shared" (`String "v1");
  Ctx.set ctx_a "a_only" (`Int 1);
  Ctx.set ctx_b "shared" (`String "v2");
  Ctx.set ctx_b "b_only" (`Int 2);
  let d = Ctx.diff ctx_a ctx_b in
  (* "b_only" is added (in b, not in a) *)
  check bool "b_only added" true (List.exists (fun (k, _) -> k = "b_only") d.added);
  (* "a_only" is removed (in a, not in b) *)
  check bool "a_only removed" true (List.mem "a_only" d.removed);
  (* "shared" is changed *)
  check bool "shared changed" true (List.exists (fun (k, _) -> k = "shared") d.changed)
;;

(* ── Runner ──────────────────────────────────────── *)

let () =
  run
    "Keeper Context Isolation"
    [ ( "basic"
      , [ test_case "separate contexts" `Quick test_basic_isolation
        ; test_case "scoped key collision" `Quick test_scoped_key_collision
        ] )
    ; ( "checkpoint"
      , [ test_case "roundtrip isolation" `Quick test_checkpoint_roundtrip_isolation
        ; test_case "copy-based resume" `Quick test_copy_resume_isolation
        ] )
    ; ( "scope"
      , [ test_case
            "cross-keeper scope isolation"
            `Quick
            test_scope_isolation_cross_keeper
        ; test_case "merge order independence" `Quick test_merge_order_independence
        ] )
    ; "diff", [ test_case "cross-keeper diff" `Quick test_diff_cross_keeper ]
    ]
;;
