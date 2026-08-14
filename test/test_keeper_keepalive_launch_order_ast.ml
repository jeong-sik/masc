open Alcotest

let fixture_path = "test/fixtures/keeper_keepalive_launch_order_ast_fixture.ml"

let dominance_in_fixture binding_name =
  Ast_grep.result_ok_match_dominates_call_in_value_binding
    ~module_path:fixture_path
    ~binding_name
    ~gate:"gate"
    ~callee:"launch_side_effect"
;;

let test_dominance_checker_rejects_unguarded_paths () =
  check bool "total gate match is accepted" true (dominance_in_fixture "guarded");
  check bool
    "error-branch side effect is rejected"
    false
    (dominance_in_fixture "side_effect_on_error");
  check bool
    "conditional gate omission is rejected"
    false
    (dominance_in_fixture "gate_omitted_on_branch")
;;

let test_launch_gate_dominates_launch_side_effects () =
  List.iter
    (fun side_effect ->
       check bool
         (Printf.sprintf "Fiber_started Ok branch dominates %s" side_effect)
         true
         (Ast_grep.result_ok_match_dominates_call_in_value_binding
            ~module_path:"lib/keeper/keeper_keepalive.ml"
            ~binding_name:"start_keepalive"
            ~gate:"dispatch_fiber_started"
            ~callee:side_effect))
    [ "bootstrap_live_keeper_meta"
    ; "publish_keeper_started"
    ; "Keeper_lane.fork"
    ; "start_keeper_grpc_heartbeat"
    ; (* A lane reached through recovery used to carry the gRPC sidecar and no
         Board-attention worker, so its Board candidates were recorded and
         never judged. Measured 2026-08-05: 532 pending candidates on four
         live keepers, the oldest 5 days old, with no failure logged anywhere
         -- there is no worker to fail. *)
      "fork_board_attention_worker"
    ]
;;

(* The lane's sidecar set must have one definition. Two lane-start paths fork
   the same registry entry's lane ([Keeper_lane.fork] rejects the second with
   [Already_started]), so whichever path wins decides what the lane contains.
   Pinning the single fork site is what keeps the two paths from drifting into
   different lanes again. *)
let test_board_worker_has_one_fork_site () =
  check int
    "keeper_keepalive owns the only Keeper_board_attention_worker.run call"
    1
    (Ast_grep.count_calls
       ~module_path:"lib/keeper/keeper_keepalive.ml"
       ~callee:"Keeper_board_attention_worker.run");
  check int
    "the supervisor does not fork its own worker"
    0
    (Ast_grep.count_calls
       ~module_path:"lib/keeper/keeper_supervisor_launch.ml"
       ~callee:"Keeper_board_attention_worker.run");
  check int
    "the supervisor lane body calls the shared fork"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/keeper/keeper_supervisor_launch.ml"
       ~binding_name:"launch_supervised_fiber_body"
       ~callee:"Keeper_keepalive.fork_board_attention_worker")
;;

let test_launch_restores_tool_usage_with_lifecycle_authority () =
  check int
    "start_keepalive uses the token-qualified restore"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/keeper/keeper_keepalive.ml"
       ~binding_name:"start_keepalive"
       ~callee:"Keeper_registry_tool_usage_persistence.restore_for_lifecycle");
  check int
    "start_keepalive does not use the name-only restore"
    0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/keeper/keeper_keepalive.ml"
       ~binding_name:"start_keepalive"
       ~callee:"Keeper_registry_tool_usage_persistence.restore")
;;

let cleanup_protect_count ~module_path ~binding_name =
  Ast_grep.count_applications_with_label_containing_call_in_value_binding
    ~module_path
    ~binding_name
    ~callee:"Eio_guard.protect"
    ~label:"finally"
    ~nested_callee:"run_cleanup_best_effort"
;;

let test_cleanup_protect_checker_rejects_omitted_helper () =
  check int
    "finally without cleanup helper is rejected"
    0
    (cleanup_protect_count
       ~module_path:fixture_path
       ~binding_name:"protected_cleanup_omitted")
;;

let test_supervisor_finally_calls_cleanup_best_effort () =
  let module_path = "lib/keeper/keeper_supervisor_launch.ml" in
  let binding_name = "launch_supervised_fiber_body" in
  (* Two nested guards: the outer one runs lane cleanup, the inner one stops
     the Board-attention worker when the heartbeat loop returns. The count was
     pinned at 1 and has been wrong since the inner guard appeared -- this
     suite is in no CI target list and declares no [deps] on the sources it
     reads, so it neither ran nor re-ran. *)
  check int
    "supervisor has two nested Eio_guard.protect"
    2
    (Ast_grep.count_calls_in_value_binding
       ~module_path
       ~binding_name
       ~callee:"Eio_guard.protect");
  check int
    "Eio_guard.protect finally calls run_cleanup_best_effort"
    1
    (cleanup_protect_count ~module_path ~binding_name)
;;

let () =
  run
    "keeper keepalive launch order"
    [ ( "start_keepalive"
      , [ test_case
            "dominance checker rejects unguarded control flow"
            `Quick
            test_dominance_checker_rejects_unguarded_paths
        ; test_case
            "Fiber_started Ok branch dominates launch side effects"
            `Quick
            test_launch_gate_dominates_launch_side_effects
        ; test_case
            "cleanup checker rejects omitted finally helper"
            `Quick
            test_cleanup_protect_checker_rejects_omitted_helper
        ; test_case
            "supervisor finally calls cleanup best effort"
            `Quick
            test_supervisor_finally_calls_cleanup_best_effort
        ; test_case
            "board attention worker has one fork site"
            `Quick
            test_board_worker_has_one_fork_site
        ; test_case
            "launch restores tool usage with lifecycle authority"
            `Quick
            test_launch_restores_tool_usage_with_lifecycle_authority
        ] )
    ]
;;
