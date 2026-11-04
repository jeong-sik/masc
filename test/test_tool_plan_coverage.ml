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

   The plan tools read and write one file, [.masc/current_task], so each
   test runs in a workspace of its own under the temp directory.
   ============================================================ *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Unix.unlink path

let unique_ctx label : Tool_plan.context =
  let base_path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "test-plan-%s-%d-%d"
         label
         (Unix.getpid ())
         (Random.bits ()))
  in
  ({ config = Masc.Workspace.default_config base_path } : Tool_plan.context)

let in_workspace label f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = unique_ctx label in
  Fun.protect
    ~finally:(fun () -> rm_rf ctx.config.Masc.Workspace.base_path)
    (fun () -> f ctx)

let dispatch (ctx : Tool_plan.context) name args =
  match Tool_plan.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> fail (Printf.sprintf "%s is not a plan tool" name)

let json = testable Yojson.Safe.pretty_print Yojson.Safe.equal

let check_ok label result expected =
  check bool (label ^ " succeeds") true (Tool_result.is_success result);
  check json (label ^ " data") expected (Tool_result.data result)

let check_failed label result expected_class =
  let name = Tool_result.tool_failure_class_to_string in
  check bool (label ^ " fails") false (Tool_result.is_success result);
  check (option string) (label ^ " failure class")
    (Some (name expected_class))
    (Option.map name (Tool_result.failure_class result))

let marker (ctx : Tool_plan.context) =
  Masc.Task.Planning_eio.get_current_task ctx.config

let set_args task_id = `Assoc [ ("task_id", `String task_id) ]

let test_marker_set_get_clear () =
  in_workspace "roundtrip" @@ fun ctx ->
  let unset = `Assoc [ ("current_task", `Null) ] in
  check_ok "get before set"
    (dispatch ctx "masc_plan_get_task" (`Assoc []))
    unset;
  check_ok "set"
    (dispatch ctx "masc_plan_set_task" (set_args "task-001"))
    (`Assoc [ ("status", `String "set"); ("current_task", `String "task-001") ]);
  check_ok "get after set"
    (dispatch ctx "masc_plan_get_task" (`Assoc []))
    (`Assoc [ ("current_task", `String "task-001") ]);
  check_ok "set again"
    (dispatch ctx "masc_plan_set_task" (set_args "task-002"))
    (`Assoc [ ("status", `String "set"); ("current_task", `String "task-002") ]);
  check (option string) "the marker holds the last value" (Some "task-002")
    (marker ctx);
  check_ok "clear"
    (dispatch ctx "masc_plan_clear_task" (`Assoc []))
    (`Assoc
       [ ("status", `String "cleared")
       ; ("message", `String "Current task cleared")
       ]);
  check_ok "get after clear"
    (dispatch ctx "masc_plan_get_task" (`Assoc []))
    unset

let test_set_without_task_id_is_refused () =
  in_workspace "missing-id" @@ fun ctx ->
  check_failed "empty task_id"
    (dispatch ctx "masc_plan_set_task" (set_args ""))
    Tool_result.Workflow_rejection;
  check_failed "absent task_id"
    (dispatch ctx "masc_plan_set_task" (`Assoc []))
    Tool_result.Workflow_rejection;
  check (option string) "nothing was written" None (marker ctx)

(* [.masc/current_task] is a directory that cannot be moved aside. The file
   store fails; the caller's arguments were fine. *)
let test_set_store_failure_is_runtime_failure () =
  if Unix.geteuid () = 0 then skip ();
  in_workspace "store-failure" @@ fun ctx ->
  let masc_dir = Workspace_utils.masc_dir ctx.config in
  let marker_path = Filename.concat masc_dir "current_task" in
  let trash = Filename.concat masc_dir "_trash" in
  Fs_compat.mkdir_p marker_path;
  Fs_compat.save_file (Filename.concat marker_path "forensics.txt") "kept";
  Fs_compat.mkdir_p trash;
  Unix.chmod trash 0o555;
  Fun.protect
    ~finally:(fun () -> Unix.chmod trash 0o755)
    (fun () ->
      check_failed "set"
        (dispatch ctx "masc_plan_set_task" (set_args "task-001"))
        Tool_result.Runtime_failure;
      check bool "the directory stays in place" true
        (Sys.is_directory marker_path);
      check (option string) "nothing was written over it" None (marker ctx))

let test_dispatch_unknown_tool () =
  match
    Tool_plan.dispatch (unique_ctx "unknown") ~name:"masc_unknown"
      ~args:(`Assoc [])
  with
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
      test_case "marker set, get, clear" `Quick test_marker_set_get_clear;
      test_case "set without task_id is refused" `Quick
        test_set_without_task_id_is_refused;
      test_case "store failure is a runtime failure" `Quick
        test_set_store_failure_is_runtime_failure;
      test_case "unknown" `Quick test_dispatch_unknown_tool;
    ];
  ]
