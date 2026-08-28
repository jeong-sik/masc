(** Tool_plan Module Coverage Tests *)

module Tool_args = Tool_args
open Alcotest

let () = Random.self_init ()

module Tool_plan = Masc.Tool_plan

(* ============================================================
   Argument Helper Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("task_id", `String "task-123")] in
  check string "extracts string" "task-123" (Tool_args.get_string args "task_id" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default" (Tool_args.get_string args "task_id" "default")

let test_get_string_wrong_type () =
  let args = `Assoc [("task_id", `Int 42)] in
  check string "uses default on type mismatch" "default" (Tool_args.get_string args "task_id" "default")

let test_get_int_exists () =
  let args = `Assoc [("index", `Int 5)] in
  check int "extracts int" 5 (Tool_args.get_int args "index" 0)

let test_get_int_missing () =
  let args = `Assoc [] in
  check int "uses default" 0 (Tool_args.get_int args "index" 0)

(* ============================================================
   Context Creation Tests
   ============================================================ *)

let test_context_creation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc.Workspace.default_config "/tmp/test" in
  let ctx : Tool_plan.context = { config } in
  check bool "context created" true (ctx.config.Masc.Workspace.base_path = "/tmp/test")

(* ============================================================
   Dispatch Tests
   ============================================================ *)

let make_ctx () : Tool_plan.context =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc.Workspace.default_config "/tmp/test-plan" in
  ({ config } : Tool_plan.context)

let make_ctx_unique label : Tool_plan.context =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "test-plan-%s-%d-%d"
         label
         (Unix.getpid ())
         (Random.bits ()))
  in
  let config = Masc.Workspace.default_config base_path in
  ({ config } : Tool_plan.context)

let planning_context_path (ctx : Tool_plan.context) task_id =
  Filename.concat
    (Filename.concat ctx.config.Masc.Workspace.base_path (Printf.sprintf "planning/%s" task_id))
    "context.json"

let planning_task_plan_path ctx task_id =
  Filename.concat (Filename.dirname (planning_context_path ctx task_id)) "task_plan.md"

let test_dispatch_plan_set_task () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_id", `String "task-001")] in
  match Tool_plan.dispatch ctx ~name:"masc_plan_set_task" ~args with
  | Some result -> check bool "succeeds" true (Tool_result.is_success result)
  | None -> fail "expected Some"

let test_dispatch_plan_set_task_empty () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_id", `String "")] in
  match Tool_plan.dispatch ctx ~name:"masc_plan_set_task" ~args with
  | Some result -> check bool "fails on empty" false (Tool_result.is_success result)
  | None -> fail "expected Some"

let test_dispatch_plan_get_task () =
  let ctx = make_ctx () in
  match Tool_plan.dispatch ctx ~name:"masc_plan_get_task" ~args:(`Assoc []) with
  | Some result -> check bool "succeeds" true (Tool_result.is_success result)
  | None -> fail "expected Some"

let test_dispatch_plan_clear_task () =
  let ctx = make_ctx () in
  match Tool_plan.dispatch ctx ~name:"masc_plan_clear_task" ~args:(`Assoc []) with
  | Some result -> check bool "succeeds" true (Tool_result.is_success result)
  | None -> fail "expected Some"

let test_dispatch_unknown_tool () =
  let ctx = make_ctx () in
  match Tool_plan.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
  | None -> ()
  | Some _ -> fail "expected None for unknown tool"

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Tool_plan Coverage" [
    "get_string", [
      test_case "exists" `Quick test_get_string_exists;
      test_case "missing" `Quick test_get_string_missing;
      test_case "wrong type" `Quick test_get_string_wrong_type;
    ];
    "get_int", [
      test_case "exists" `Quick test_get_int_exists;
      test_case "missing" `Quick test_get_int_missing;
    ];
    "context", [
      test_case "creation" `Quick test_context_creation;
    ];
    "dispatch", [
      test_case "plan_set_task" `Quick test_dispatch_plan_set_task;
      test_case "plan_set_task_empty" `Quick test_dispatch_plan_set_task_empty;
      test_case "plan_get_task" `Quick test_dispatch_plan_get_task;
      test_case "plan_clear_task" `Quick test_dispatch_plan_clear_task;
      test_case "unknown" `Quick test_dispatch_unknown_tool;
    ];
  ]
