(** test_keeper_subprocess_registry — RFC-0036 Phase A.3 registry tests.

    Pure API tests — no real subprocesses are spawned.
    Drain is exercised with synthetic pids that will fail Unix.kill
    (ESRCH); this proves drain doesn't crash on already-reaped or
    bogus pids and that the registry is cleared regardless. *)

open Alcotest

module R = Masc_mcp.Keeper_subprocess_registry
module H = Masc_mcp.Keeper_lifecycle_hooks

let setup () =
  R.reset_for_testing ();
  H.reset_for_testing ()

let test_register_unregister_pids_for () =
  setup ();
  check (list int) "starts empty" [] (R.pids_for ~keeper_id:"k1");
  R.register ~keeper_id:"k1" ~pid:1001;
  R.register ~keeper_id:"k1" ~pid:1002;
  R.register ~keeper_id:"k2" ~pid:2001;
  check (list int) "k1 has both"  [ 1001; 1002 ] (R.pids_for ~keeper_id:"k1");
  check (list int) "k2 has one"   [ 2001 ]       (R.pids_for ~keeper_id:"k2");
  check int        "total = 3"    3              (R.total_pids ());
  R.unregister ~keeper_id:"k1" ~pid:1001;
  check (list int) "k1 after unreg" [ 1002 ] (R.pids_for ~keeper_id:"k1");
  check int        "total = 2"      2        (R.total_pids ())

let test_register_idempotent () =
  setup ();
  R.register ~keeper_id:"k" ~pid:42;
  R.register ~keeper_id:"k" ~pid:42;
  R.register ~keeper_id:"k" ~pid:42;
  check (list int) "single entry" [ 42 ] (R.pids_for ~keeper_id:"k");
  check int        "total = 1"     1     (R.total_pids ())

let test_unregister_unknown_is_noop () =
  setup ();
  R.unregister ~keeper_id:"never-registered" ~pid:99;
  R.register ~keeper_id:"k" ~pid:1;
  R.unregister ~keeper_id:"k" ~pid:9999;  (* wrong pid *)
  check (list int) "still has 1" [ 1 ] (R.pids_for ~keeper_id:"k")

let test_drain_with_no_pids () =
  setup ();
  let r = R.drain ~keeper_id:"empty" ~grace_ms:50 in
  check int "inspected"   0 r.R.inspected;
  check int "sigterm"     0 r.R.sigterm_sent;
  check int "sigkill"     0 r.R.sigkill_sent;
  check int "still_alive" 0 r.R.still_alive

let test_drain_clears_registry () =
  setup ();
  (* Use very high pids unlikely to exist. Unix.kill will fail with
     ESRCH, but drain should still remove them from the registry. *)
  R.register ~keeper_id:"k" ~pid:0x7FFFFFF0;
  R.register ~keeper_id:"k" ~pid:0x7FFFFFF1;
  let r = R.drain ~keeper_id:"k" ~grace_ms:50 in
  check int "inspected = 2" 2 r.R.inspected;
  (* sigterm_sent may be 0 (kill failed with ESRCH); the post-condition
     we care about is that the registry is empty. *)
  check (list int) "registry cleared" [] (R.pids_for ~keeper_id:"k");
  check int "total = 0" 0 (R.total_pids ())

let test_drain_grace_ms_clamped () =
  setup ();
  (* No pids → drain returns immediately regardless of grace_ms. The
     clamp logic still runs; just verify no crash on extreme values. *)
  let _ = R.drain ~keeper_id:"e" ~grace_ms:(-100) in
  let _ = R.drain ~keeper_id:"e" ~grace_ms:1_000_000 in
  check pass "no crash on extreme grace_ms" () ()

let test_default_hook_idempotent_registration () =
  setup ();
  check int "no hooks initially" 0 (H.registered_count ());
  R.register_default_cleanup_hook ();
  check int "one hook"           1 (H.registered_count ());
  R.register_default_cleanup_hook ();
  R.register_default_cleanup_hook ();
  check int "still one hook (idempotent)" 1 (H.registered_count ())

let test_default_hook_drains_on_tombstone () =
  setup ();
  R.register ~keeper_id:"k" ~pid:0x7FFFFFF2;
  R.register_default_cleanup_hook ();
  H.run ~keeper_id:"k" H.Tombstone_reaped;
  check (list int) "registry drained by hook" [] (R.pids_for ~keeper_id:"k")

let test_default_hook_ignores_phase_transition () =
  setup ();
  R.register ~keeper_id:"k" ~pid:0x7FFFFFF3;
  R.register_default_cleanup_hook ();
  H.run ~keeper_id:"k"
    (H.Phase_transition
       { from_phase = Masc_mcp.Keeper_state_machine.Running;
         to_phase   = Masc_mcp.Keeper_state_machine.Failing });
  (* Phase_transition must not drain. *)
  check (list int) "still tracked" [ 0x7FFFFFF3 ] (R.pids_for ~keeper_id:"k")

let () =
  run "Keeper_subprocess_registry" [
    "registry", [
      test_case "register/unregister/pids_for" `Quick test_register_unregister_pids_for;
      test_case "register is idempotent"       `Quick test_register_idempotent;
      test_case "unregister unknown is noop"   `Quick test_unregister_unknown_is_noop;
    ];
    "drain", [
      test_case "no-op when empty"     `Quick test_drain_with_no_pids;
      test_case "clears registry"      `Quick test_drain_clears_registry;
      test_case "grace_ms clamped"     `Quick test_drain_grace_ms_clamped;
    ];
    "default_hook", [
      test_case "registration is idempotent"        `Quick test_default_hook_idempotent_registration;
      test_case "drains on Tombstone_reaped"        `Quick test_default_hook_drains_on_tombstone;
      test_case "ignores Phase_transition"          `Quick test_default_hook_ignores_phase_transition;
    ];
  ]
