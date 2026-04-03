(** Tool_portal Module Coverage Tests *)

module Tool_args = Masc_mcp.Tool_args
open Alcotest

let () = Random.self_init ()

module Tool_portal = Masc_mcp.Tool_portal

let temp_dir () =
  let dir = Filename.temp_file "test_tool_portal_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

(* ============================================================
   Argument Helper Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("target_agent", `String "claude-001")] in
  check string "extracts string" "claude-001" (Tool_args.get_string args "target_agent" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default" (Tool_args.get_string args "target_agent" "default")

let test_get_string_opt_exists () =
  let args = `Assoc [("initial_message", `String "hello")] in
  check (option string) "extracts option" (Some "hello") (Tool_args.get_string_opt args "initial_message")

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  check (option string) "returns None" None (Tool_args.get_string_opt args "initial_message")

let test_get_string_opt_empty () =
  let args = `Assoc [("initial_message", `String "")] in
  check (option string) "empty is None" None (Tool_args.get_string_opt args "initial_message")

(* ============================================================
   Context Creation Tests
   ============================================================ *)

let test_context_creation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Room.default_config "/tmp/test" in
  let ctx : Tool_portal.context = { config; agent_name = "test-agent" } in
  check string "agent_name" "test-agent" ctx.agent_name

(* ============================================================
   Dispatch Tests
   ============================================================ *)

let make_ctx () : Tool_portal.context =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Room.default_config "/tmp/test-portal" in
  ({ config; agent_name = "test-agent" } : Tool_portal.context)

let test_dispatch_portal_open () =
  let ctx = make_ctx () in
  let args = `Assoc [("target_agent", `String "claude-002")] in
  try
    match Tool_portal.dispatch ctx ~name:"masc_portal_open" ~args with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_portal_send () =
  let ctx = make_ctx () in
  let args = `Assoc [("message", `String "hello")] in
  try
    match Tool_portal.dispatch ctx ~name:"masc_portal_send" ~args with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_portal_close () =
  let ctx = make_ctx () in
  try
    match Tool_portal.dispatch ctx ~name:"masc_portal_close" ~args:(`Assoc []) with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_portal_status () =
  let ctx = make_ctx () in
  try
    match Tool_portal.dispatch ctx ~name:"masc_portal_status" ~args:(`Assoc []) with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_unknown_tool () =
  let ctx = make_ctx () in
  match Tool_portal.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
  | None -> ()
  | Some _ -> fail "expected None for unknown tool"

let test_filter_visible_tool_names_without_portal () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "test-agent"));
      let ctx : Tool_portal.context = { config; agent_name = "test-agent" } in
      let visible =
        Tool_portal.filter_visible_tool_names ctx
          [ "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
            "masc_portal_status"; "keeper_tasks_list" ]
      in
      check (list string) "closed portal keeps open+status"
        [ "masc_portal_open"; "masc_portal_status"; "keeper_tasks_list" ]
        visible)

let test_filter_visible_tool_names_with_portal () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let config = Masc_mcp.Room.default_config base_dir in
      ignore (Masc_mcp.Room.init config ~agent_name:(Some "test-agent"));
      ignore
        (Masc_mcp.Room.portal_open_r config ~agent_name:"test-agent"
           ~target_agent:"claude-002" ~initial_message:None);
      let ctx : Tool_portal.context = { config; agent_name = "test-agent" } in
      let visible =
        Tool_portal.filter_visible_tool_names ctx
          [ "masc_portal_open"; "masc_portal_send"; "masc_portal_close";
            "masc_portal_status"; "keeper_tasks_list" ]
      in
      check (list string) "open portal keeps send+close+status"
        [ "masc_portal_send"; "masc_portal_close"; "masc_portal_status";
          "keeper_tasks_list" ]
        visible)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Tool_portal Coverage" [
    "get_string", [
      test_case "exists" `Quick test_get_string_exists;
      test_case "missing" `Quick test_get_string_missing;
    ];
    "get_string_opt", [
      test_case "exists" `Quick test_get_string_opt_exists;
      test_case "missing" `Quick test_get_string_opt_missing;
      test_case "empty" `Quick test_get_string_opt_empty;
    ];
    "context", [
      test_case "creation" `Quick test_context_creation;
    ];
    "dispatch", [
      test_case "portal_open" `Quick test_dispatch_portal_open;
      test_case "portal_send" `Quick test_dispatch_portal_send;
      test_case "portal_close" `Quick test_dispatch_portal_close;
      test_case "portal_status" `Quick test_dispatch_portal_status;
      test_case "unknown" `Quick test_dispatch_unknown_tool;
      test_case "filter visible without portal" `Quick
        test_filter_visible_tool_names_without_portal;
      test_case "filter visible with portal" `Quick
        test_filter_visible_tool_names_with_portal;
    ];
  ]
