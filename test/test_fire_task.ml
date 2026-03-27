(** Tool_fire_task — Fire-and-forget task tool tests.

    Tests use filesystem backend (Room.default_config) with temp dirs.
    Background spawn is NOT tested (requires real CLI and blocks on
    subprocess). We verify:
    1. Schema presence and structure
    2. Dispatch routing (known/unknown tools)
    3. Argument validation (missing goal)
    4. Task creation in room backlog (via direct Room API)
    5. Immediate response structure (via a mock-friendly approach)

    The actual agent spawn is tested via the full integration path,
    not in unit tests. *)

open Alcotest

module Tool_fire_task = Masc_mcp.Tool_fire_task
module Tool_args = Masc_mcp.Tool_args
module Room = Masc_mcp.Room

(* ============================================================
   Helpers
   ============================================================ *)

let temp_counter = ref 0

let with_temp_dir f =
  incr temp_counter;
  let dir = Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-fire-test-%d-%d-%d"
       (Unix.getpid ()) !temp_counter (Random.int 999999))
  in
  (* Clean up any stale dir from previous run *)
  if Sys.file_exists dir then
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)));
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () ->
    ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))
  ) (fun () -> f dir)

let init_room dir =
  let config = Room.default_config dir in
  let _msg = Room.init config ~agent_name:None in
  config

(* ============================================================
   Schema Tests
   ============================================================ *)

let test_schema_count () =
  let schemas = Tool_fire_task.schemas in
  check int "one schema" 1 (List.length schemas)

let test_schema_name () =
  let schemas = Tool_fire_task.schemas in
  let first = List.hd schemas in
  check string "name" "masc_fire_task" first.name

let test_schema_has_required_goal () =
  let schemas = Tool_fire_task.schemas in
  let first = List.hd schemas in
  let module U = Yojson.Safe.Util in
  let required = first.input_schema |> U.member "required" |> U.to_list in
  let required_names = List.map U.to_string required in
  check bool "goal is required" true (List.mem "goal" required_names)

let test_schema_optional_fields () =
  let schemas = Tool_fire_task.schemas in
  let first = List.hd schemas in
  let module U = Yojson.Safe.Util in
  let props = first.input_schema |> U.member "properties" in
  (* agent, priority, use_worktree should be present as optional *)
  let has key = match props |> U.member key with `Null -> false | _ -> true in
  check bool "has agent" true (has "agent");
  check bool "has priority" true (has "priority");
  check bool "has use_worktree" true (has "use_worktree")

(* ============================================================
   Dispatch Routing Tests (no fiber spawn)
   ============================================================ *)

let test_dispatch_unknown_tool () =
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run (fun sw ->
      with_temp_dir (fun dir ->
        let config = init_room dir in
        let ctx : Tool_fire_task.context = { config; agent_name = "test"; sw } in
        match Tool_fire_task.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
        | None -> ()
        | Some _ -> fail "expected None for unknown tool"
      )
    )
  )

let test_dispatch_missing_goal () =
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Switch.run (fun sw ->
      with_temp_dir (fun dir ->
        let config = init_room dir in
        let ctx : Tool_fire_task.context = { config; agent_name = "test"; sw } in
        match Tool_fire_task.dispatch ctx ~name:"masc_fire_task" ~args:(`Assoc []) with
        | Some (success, msg) ->
          check bool "should fail" false success;
          check bool "mentions goal" true
            (try ignore (Str.search_forward (Str.regexp_string "goal") msg 0); true
             with Not_found -> false)
        | None -> fail "expected Some for known tool"
      )
    )
  )

(* ============================================================
   Task Creation Tests (verify room backlog, skip daemon)
   ============================================================ *)

let test_task_creation_in_backlog () =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    with_temp_dir (fun dir ->
      let config = init_room dir in
      let result = Room.add_task config
        ~title:"Test fire task goal"
        ~priority:2
        ~description:"Fire-and-forget task" in
      (* Verify task was created *)
      check bool "result contains task-" true
        (try ignore (Str.search_forward (Str.regexp_string "task-") result 0); true
         with Not_found -> false);
      (* Verify it shows in status *)
      let status = Room.status config in
      check bool "task visible in status" true
        (try ignore (Str.search_forward (Str.regexp_string "Test fire task goal") status 0); true
         with Not_found -> false)
    ))

let test_task_priority_defaults () =
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    with_temp_dir (fun dir ->
      let config = init_room dir in
      let _result = Room.add_task config
        ~title:"Default priority task"
        ~priority:3
        ~description:"Fire-and-forget task" in
      (* Verify task exists in status output *)
      let status = Room.status config in
      check bool "task title in status" true
        (try ignore (Str.search_forward (Str.regexp_string "Default priority task") status 0); true
         with Not_found -> false);
      (* Verify priority is persisted in backlog (status output does not include priority) *)
      let backlog = Room.read_backlog config in
      check bool "task has correct priority" true
        (List.exists
           (fun (t : Types_core.task) ->
             t.title = "Default priority task" && t.priority = 3)
           backlog.tasks)
    ))

(* ============================================================
   Argument Parsing Tests
   ============================================================ *)

let test_args_get_string_default () =
  let args = `Assoc [] in
  check string "default agent" "claude" (Tool_args.get_string args "agent" "claude")

let test_args_get_string_override () =
  let args = `Assoc [("agent", `String "gemini")] in
  check string "overridden agent" "gemini" (Tool_args.get_string args "agent" "claude")

let test_args_get_bool_default () =
  let args = `Assoc [] in
  check bool "default use_worktree" false (Tool_args.get_bool args "use_worktree" false)

let test_args_get_bool_true () =
  let args = `Assoc [("use_worktree", `Bool true)] in
  check bool "true use_worktree" true (Tool_args.get_bool args "use_worktree" false)

let test_args_get_int_default () =
  let args = `Assoc [] in
  check int "default priority" 3 (Tool_args.get_int args "priority" 3)

let test_args_get_int_override () =
  let args = `Assoc [("priority", `Int 1)] in
  check int "overridden priority" 1 (Tool_args.get_int args "priority" 3)

(* ============================================================
   Response Format Tests (test JSON structure)
   ============================================================ *)

let test_ok_result_format () =
  let (success, msg) = Tool_args.ok_result [
    ("task_id", `String "task-001");
    ("status", `String "spawned");
  ] in
  check bool "success" true success;
  let json = Yojson.Safe.from_string msg in
  let module U = Yojson.Safe.Util in
  check string "status field" "ok" (json |> U.member "status" |> U.to_string);
  check string "task_id" "task-001" (json |> U.member "task_id" |> U.to_string)

let test_error_result_format () =
  let (success, msg) = Tool_args.error_result "goal is required" in
  check bool "failure" false success;
  let json = Yojson.Safe.from_string msg in
  let module U = Yojson.Safe.Util in
  check string "status field" "error" (json |> U.member "status" |> U.to_string)

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Tool_fire_task" [
    "schema", [
      test_case "count" `Quick test_schema_count;
      test_case "name" `Quick test_schema_name;
      test_case "required_goal" `Quick test_schema_has_required_goal;
      test_case "optional_fields" `Quick test_schema_optional_fields;
    ];
    "dispatch", [
      test_case "unknown_tool" `Quick test_dispatch_unknown_tool;
      test_case "missing_goal" `Quick test_dispatch_missing_goal;
    ];
    "task_creation", [
      test_case "backlog" `Quick test_task_creation_in_backlog;
      test_case "priority_defaults" `Quick test_task_priority_defaults;
    ];
    "args", [
      test_case "string_default" `Quick test_args_get_string_default;
      test_case "string_override" `Quick test_args_get_string_override;
      test_case "bool_default" `Quick test_args_get_bool_default;
      test_case "bool_true" `Quick test_args_get_bool_true;
      test_case "int_default" `Quick test_args_get_int_default;
      test_case "int_override" `Quick test_args_get_int_override;
    ];
    "response_format", [
      test_case "ok_result" `Quick test_ok_result_format;
      test_case "error_result" `Quick test_error_result_format;
    ];
  ]
