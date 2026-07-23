(* Exhaustive tests for Server_state_product — orthogonal FSM composition.
   Covers per-dimension transitions, cross-dimension invariants,
   lifecycle chains, and JSON serialization. *)

open Alcotest

module S = Masc.Server_state_product
open S.Lifecycle
open S.Backend
open S.Lazy_task_queue
open S.Readiness

(* ── Helpers ────────────────────────────────────────────── *)

let check_ok msg = function
  | Ok v -> v
  | Error e -> failf "%s: got Error %s" msg e

let check_err msg = function
  | Ok _ -> failf "%s: expected Error" msg
  | Error _ -> ()

(* ── Dimension 1: Lifecycle ─────────────────────────────── *)

let test_lifecycle_boot_complete () =
  let r = S.Lifecycle.apply_event ~current:Booting Boot_complete in
  check (of_pp S.Lifecycle.pp_phase) "serving" Serving
    (match r with Applied p -> p | Ignored _ -> fail "ignored");
  check bool "not ignored" true
    (match r with Applied _ -> true | _ -> false)

let test_lifecycle_ignored () =
  let r = S.Lifecycle.apply_event ~current:Serving Boot_complete in
  check bool "ignored" true
    (match r with Ignored _ -> true | _ -> false)

let test_lifecycle_all_transitions () =
  let transitions = [
    (Booting, Boot_complete, Serving);
    (Serving, Start_draining, Draining);
    (Draining, Stop, Stopped);
  ] in
  List.iter (fun (from, evt, expected) ->
    let r = S.Lifecycle.apply_event ~current:from evt in
    match r with
    | Applied p -> check (of_pp S.Lifecycle.pp_phase) "transition" expected p
    | Ignored _ -> failf "transition %s -> %s was ignored"
                      (S.Lifecycle.phase_to_string from)
                      (S.Lifecycle.event_to_string evt)
  ) transitions

(* ── Dimension 2: Backend ───────────────────────────────── *)

let test_backend_resolve () =
  let r = S.Backend.apply_event ~current:Uninitialized Resolve_fs in
  check (of_pp S.Backend.pp_phase) "filesystem" Filesystem
    (match r with Applied p -> p | Ignored _ -> fail "ignored")

let test_backend_resolve_memory () =
  let r = S.Backend.apply_event ~current:Uninitialized Resolve_memory in
  check (of_pp S.Backend.pp_phase) "memory" Memory
    (match r with Applied p -> p | Ignored _ -> fail "ignored")

let test_backend_degrade () =
  let r = S.Backend.apply_event ~current:Filesystem (Degrade "conn_reset") in
  check (of_pp S.Backend.pp_phase) "degraded" Degraded
    (match r with Applied p -> p | Ignored _ -> fail "ignored")

let test_backend_recover () =
  let r = S.Backend.apply_event ~current:Degraded Recover in
  check (of_pp S.Backend.pp_phase) "filesystem" Filesystem
    (match r with Applied p -> p | Ignored _ -> fail "ignored")

(* ── Dimension 3: Lazy Task Queue ───────────────────────── *)

let test_lazy_tasks_appear () =
  let r = S.Lazy_task_queue.apply_event ~current:Complete (Tasks_appear ["a"; "b"]) in
  check (of_pp S.Lazy_task_queue.pp) "pending" (Pending ["a"; "b"]) r

let test_lazy_task_finish () =
  let current = Pending ["a"; "b"] in
  let r = S.Lazy_task_queue.apply_event ~current (Task_finish "a") in
  check (of_pp S.Lazy_task_queue.pp) "pending[b]" (Pending ["b"]) r;
  let r2 = S.Lazy_task_queue.apply_event ~current:r (Task_finish "b") in
  check (of_pp S.Lazy_task_queue.pp) "complete" Complete r2

let test_lazy_task_fail () =
  let current = Pending ["a"; "b"] in
  let r = S.Lazy_task_queue.apply_event ~current (Task_fail { task = "a"; error = "x" }) in
  check (of_pp S.Lazy_task_queue.pp) "pending[b]" (Pending ["b"]) r

(* ── Dimension 4: Readiness ─────────────────────────────── *)

let test_readiness_set_ready () =
  let r = S.Readiness.apply_event ~current:NotReady Set_ready in
  check (of_pp S.Readiness.pp_phase) "ready" Ready
    (match r with Applied p -> p | Ignored _ -> fail "ignored")

let test_readiness_set_not_ready () =
  let r = S.Readiness.apply_event ~current:Ready Set_not_ready in
  check (of_pp S.Readiness.pp_phase) "not_ready" NotReady
    (match r with Applied p -> p | Ignored _ -> fail "ignored")

(* ── Cross-Dimension Invariants ─────────────────────────── *)

let test_invariant_i1_ready_not_booting () =
  let state = { S.initial with readiness = Ready; lifecycle = Booting } in
  check_err "I1 violated" (S.check_invariants state)

let test_invariant_i2_stopped_not_ready () =
  let state = { S.initial with lifecycle = Stopped; readiness = Ready } in
  check_err "I2 violated" (S.check_invariants state)

let test_invariant_i3_pending_blocks_stop () =
  let state =
    { S.initial with
      lifecycle = Stopped;
      lazy_tasks = Pending ["x"]
    }
  in
  check_err "I3 violated" (S.check_invariants state)

let test_invariant_i4_degraded_not_ready () =
  let state =
    { S.initial with
      backend = Degraded;
      readiness = Ready
    }
  in
  check_err "I4 violated" (S.check_invariants state)

let test_invariant_i5_booting_uninitialized () =
  let state =
    { S.initial with
      lifecycle = Booting;
      backend = Filesystem
    }
  in
  check_err "I5 violated" (S.check_invariants state)

let test_invariant_all_valid () =
  let state =
    { S.initial with
      lifecycle = Serving;
      backend = Filesystem;
      readiness = Ready;
      lazy_tasks = Complete
    }
  in
  check_ok "valid state" (S.check_invariants state)

(* ── Per-Dimension Event Application ────────────────────── *)

let test_apply_lifecycle_event () =
  let state = S.initial in
  let state =
    check_ok "boot complete"
      (S.apply_lifecycle_event state Boot_complete)
  in
  check (of_pp S.Lifecycle.pp_phase) "serving" Serving state.lifecycle;
  let state =
    check_ok "resolve backend"
      (S.apply_backend_event state Resolve_fs)
  in
  check (of_pp S.Backend.pp_phase) "filesystem" Filesystem state.backend;
  let state =
    check_ok "set ready"
      (S.apply_readiness_event state Set_ready)
  in
  check (of_pp S.Readiness.pp_phase) "ready" Ready state.readiness

let test_apply_backend_event_degrade () =
  let state =
    { S.initial with
      lifecycle = Serving;
      backend = Filesystem;
      readiness = Ready
    }
  in
  (* Degrading backend while ready should fail invariant I4 *)
  check_err "degrade while ready"
    (S.apply_backend_event state (S.Backend.Degrade "fail"))

let test_apply_backend_event_degrade_after_not_ready () =
  let state =
    { S.initial with
      lifecycle = Serving;
      backend = Filesystem;
      readiness = NotReady
    }
  in
  let state =
    check_ok "degrade after not_ready"
      (S.apply_backend_event state (S.Backend.Degrade "fail"))
  in
  check (of_pp S.Backend.pp_phase) "degraded" Degraded state.backend

let test_apply_lazy_event () =
  let state = { S.initial with lifecycle = Serving; readiness = Ready } in
  let state =
    check_ok "tasks appear"
      (S.apply_lazy_event state (S.Lazy_task_queue.Tasks_appear ["a"]))
  in
  check (of_pp S.Lazy_task_queue.pp) "pending" (Pending ["a"]) state.lazy_tasks;
  let state =
    check_ok "task finish"
      (S.apply_lazy_event state (S.Lazy_task_queue.Task_finish "a"))
  in
  check (of_pp S.Lazy_task_queue.pp) "complete" Complete state.lazy_tasks

(* ── Derived Flat Phase ─────────────────────────────────── *)

let test_derive_flat_phase () =
  let check_phase expected state =
    check (of_pp S.pp_flat_phase) (S.flat_phase_to_string expected) expected
      (S.derive_flat_phase state)
  in
  check_phase Blocking { S.initial with lifecycle = Booting };
  check_phase Degraded
    { S.initial with lifecycle = Serving; backend = Degraded };
  check_phase Lazy
    { S.initial with
      lifecycle = Serving;
      lazy_tasks = Pending ["x"];
      readiness = Ready
    };
  check_phase Ready
    { S.initial with
      lifecycle = Serving;
      lazy_tasks = Complete;
      readiness = Ready
    };
  check_phase Blocking
    { S.initial with lifecycle = Stopped };
  check_phase Ready
    { S.initial with lifecycle = Draining; readiness = Ready };
  check_phase Blocking
    { S.initial with lifecycle = Draining; readiness = NotReady }

(* ── JSON Serialization ─────────────────────────────────── *)

let test_product_to_json () =
  let json = S.product_to_json S.initial in
  match json with
  | `Assoc fields ->
    check bool "has lifecycle" true (List.mem_assoc "lifecycle" fields);
    check bool "has backend" true (List.mem_assoc "backend" fields);
    check bool "has lazy_tasks" true (List.mem_assoc "lazy_tasks" fields);
    check bool "has readiness" true (List.mem_assoc "readiness" fields);
    check bool "has flat_phase" true (List.mem_assoc "flat_phase" fields);
    (match List.assoc "lifecycle" fields with
     | `String "booting" -> ()
     | _ -> fail "lifecycle should be booting");
    (match List.assoc "flat_phase" fields with
     | `String "blocking" -> ()
     | _ -> fail "flat_phase should be blocking")
  | _ -> fail "expected assoc"

(* ── Lifecycle Chain (Boot -> Serve -> Drain -> Stop) ───── *)

let test_lifecycle_chain () =
  let state = S.initial in
  let state =
    check_ok "boot complete"
      (S.apply_lifecycle_event state Boot_complete)
  in
  check (of_pp S.Lifecycle.pp_phase) "serving" Serving state.lifecycle;
  let state =
    check_ok "resolve fs"
      (S.apply_backend_event state Resolve_fs)
  in
  let state =
    check_ok "set ready"
      (S.apply_readiness_event state Set_ready)
  in
  check (of_pp S.Readiness.pp_phase) "ready" Ready state.readiness;

  let state =
    check_ok "tasks appear"
      (S.apply_lazy_event state (S.Lazy_task_queue.Tasks_appear ["init"]))
  in
  check (of_pp S.Lazy_task_queue.pp) "pending" (Pending ["init"]) state.lazy_tasks;

  let state =
    check_ok "task finish"
      (S.apply_lazy_event state (S.Lazy_task_queue.Task_finish "init"))
  in
  check (of_pp S.Lazy_task_queue.pp) "complete" Complete state.lazy_tasks;

  let state =
    check_ok "start draining"
      (S.apply_lifecycle_event state S.Lifecycle.Start_draining)
  in
  check (of_pp S.Lifecycle.pp_phase) "draining" Draining state.lifecycle;

  let state =
    check_ok "set not ready"
      (S.apply_readiness_event state S.Readiness.Set_not_ready)
  in
  let state =
    check_ok "stop"
      (S.apply_lifecycle_event state S.Lifecycle.Stop)
  in
  check (of_pp S.Lifecycle.pp_phase) "stopped" Stopped state.lifecycle;
  check (of_pp S.Readiness.pp_phase) "not_ready" NotReady state.readiness

(* ── Backend Degrade -> Recover Cycle ───────────────────── *)

let test_backend_degrade_recover_cycle () =
  let state =
    { S.initial with
      lifecycle = Serving;
      backend = Filesystem;
      readiness = NotReady
    }
  in
  let state =
    check_ok "degrade"
      (S.apply_backend_event state (S.Backend.Degrade "timeout"))
  in
  check (of_pp S.Backend.pp_phase) "degraded" Degraded state.backend;

  let state =
    check_ok "recover"
      (S.apply_backend_event state S.Backend.Recover)
  in
  check (of_pp S.Backend.pp_phase) "filesystem" Filesystem state.backend

(* ── Entry Point ────────────────────────────────────────── *)

let () =
  run "server_state_product"
    [
      ("lifecycle",
       [ test_case "boot_complete" `Quick test_lifecycle_boot_complete;
         test_case "ignored" `Quick test_lifecycle_ignored;
         test_case "all transitions" `Quick test_lifecycle_all_transitions;
       ]);
      ("backend",
       [ test_case "resolve_fs" `Quick test_backend_resolve;
         test_case "resolve_memory" `Quick test_backend_resolve_memory;
         test_case "degrade" `Quick test_backend_degrade;
         test_case "recover" `Quick test_backend_recover;
       ]);
      ("lazy_task_queue",
       [ test_case "tasks_appear" `Quick test_lazy_tasks_appear;
         test_case "task_finish" `Quick test_lazy_task_finish;
         test_case "task_fail" `Quick test_lazy_task_fail;
       ]);
      ("readiness",
       [ test_case "set_ready" `Quick test_readiness_set_ready;
         test_case "set_not_ready" `Quick test_readiness_set_not_ready;
       ]);
      ("invariants",
       [ test_case "I1 ready_not_booting" `Quick test_invariant_i1_ready_not_booting;
         test_case "I2 stopped_not_ready" `Quick test_invariant_i2_stopped_not_ready;
         test_case "I3 pending_blocks_stop" `Quick test_invariant_i3_pending_blocks_stop;
         test_case "I4 degraded_not_ready" `Quick test_invariant_i4_degraded_not_ready;
         test_case "I5 booting_uninitialized" `Quick test_invariant_i5_booting_uninitialized;
         test_case "all_valid" `Quick test_invariant_all_valid;
       ]);
      ("apply_events",
       [ test_case "lifecycle_chain" `Quick test_apply_lifecycle_event;
         test_case "backend_degrade_guard" `Quick test_apply_backend_event_degrade;
         test_case "backend_degrade_ok" `Quick test_apply_backend_event_degrade_after_not_ready;
         test_case "lazy_events" `Quick test_apply_lazy_event;
       ]);
      ("derive_flat_phase",
       [ test_case "mappings" `Quick test_derive_flat_phase;
       ]);
      ("json",
       [ test_case "product_to_json" `Quick test_product_to_json;
       ]);
      ("integration",
       [ test_case "lifecycle_chain" `Quick test_lifecycle_chain;
         test_case "degrade_recover" `Quick test_backend_degrade_recover_cycle;
       ]);
    ]
