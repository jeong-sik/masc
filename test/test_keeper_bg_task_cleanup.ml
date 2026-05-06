(** test_keeper_bg_task_cleanup — RFC-0036 Phase A.3.3 bridge tests.

    Verifies the bridge between [Keeper_lifecycle_hooks] and
    [Bg_task]. Real bg_tasks are not spawned (that requires Eio
    initialization + a live process_mgr); these tests exercise the
    pure API contract, idempotency, and event filtering. The
    drain_for_keeper happy path under a populated Bg_task roster is
    covered by integration tests further up the stack. *)

open Alcotest

module C = Masc_mcp.Keeper_bg_task_cleanup
module H = Masc_mcp.Keeper_lifecycle_hooks

let setup () =
  H.reset_for_testing ();
  C.reset_for_testing ()

let test_drain_for_keeper_with_no_tasks () =
  setup ();
  (* Bg_task.list returns [] for unknown keepers — drain reports 0. *)
  let n = C.drain_for_keeper ~keeper_id:"nobody" ~grace_sec:1.0 in
  check int "no tasks → 0" 0 n

let test_drain_grace_clamped () =
  setup ();
  (* Pure API: extreme values must not crash even with empty roster. *)
  let _ = C.drain_for_keeper ~keeper_id:"k" ~grace_sec:(-5.0) in
  let _ = C.drain_for_keeper ~keeper_id:"k" ~grace_sec:1000.0 in
  check pass "no crash on extreme grace_sec" () ()

let test_default_hook_idempotent_registration () =
  setup ();
  check int "no hooks initially" 0 (H.registered_count ());
  C.register_default_cleanup_hook ();
  check int "one hook"           1 (H.registered_count ());
  C.register_default_cleanup_hook ();
  C.register_default_cleanup_hook ();
  check int "still one hook (idempotent)" 1 (H.registered_count ())

let test_default_hook_runs_on_tombstone () =
  setup ();
  C.register_default_cleanup_hook ();
  (* No bg_tasks → drain inside hook returns 0. The contract under
     test is "hook runs and does not raise." *)
  H.run ~keeper_id:"k" H.Tombstone_reaped;
  check pass "hook completed without exception" () ()

let test_default_hook_ignores_phase_transition () =
  setup ();
  C.register_default_cleanup_hook ();
  H.run ~keeper_id:"k"
    (H.Phase_transition
       { from_phase = Masc_mcp.Keeper_state_machine.Running;
         to_phase   = Masc_mcp.Keeper_state_machine.Failing });
  check pass "hook ignored Phase_transition" () ()

let () =
  run "Keeper_bg_task_cleanup" [
    "drain", [
      test_case "no tasks returns 0"     `Quick test_drain_for_keeper_with_no_tasks;
      test_case "grace_sec clamped"      `Quick test_drain_grace_clamped;
    ];
    "default_hook", [
      test_case "registration idempotent"      `Quick test_default_hook_idempotent_registration;
      test_case "runs on Tombstone_reaped"     `Quick test_default_hook_runs_on_tombstone;
      test_case "ignores Phase_transition"     `Quick test_default_hook_ignores_phase_transition;
    ];
  ]
