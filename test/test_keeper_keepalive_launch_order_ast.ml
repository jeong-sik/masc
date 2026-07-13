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
    ]
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
  check int
    "supervisor has one Eio_guard.protect"
    1
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
        ] )
    ]
;;
