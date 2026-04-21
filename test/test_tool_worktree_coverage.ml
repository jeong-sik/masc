(** Tool_worktree Module Coverage Tests *)

module Tool_args = Masc_mcp.Tool_args
open Alcotest

let () = Random.self_init ()

module Tool_worktree = Masc_mcp.Tool_worktree

(* ============================================================
   Argument Helper Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("task_id", `String "task-001")] in
  check string "extracts string" "task-001" (Tool_args.get_string args "task_id" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default" (Tool_args.get_string args "task_id" "default")

let test_get_string_base_branch () =
  let args = `Assoc [("base_branch", `String "main")] in
  check string "extracts branch" "main"
    (Tool_args.get_string args "base_branch" Tool_worktree.default_base_branch)

let test_get_string_base_branch_default () =
  let args = `Assoc [] in
  check string "uses auto default" "auto"
    (Tool_args.get_string args "base_branch" Tool_worktree.default_base_branch)

(* ============================================================
   Context Creation Tests
   ============================================================ *)

let test_context_creation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Coord.default_config "/tmp/test" in
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  check string "agent_name" "test-agent" ctx.agent_name

(* ============================================================
   Dispatch Tests
   ============================================================ *)

let make_ctx () : Tool_worktree.context =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Masc_mcp.Coord.default_config "/tmp/test-worktree" in
  ({ config; agent_name = "test-agent" } : Tool_worktree.context)

let temp_dir () =
  let dir = Filename.temp_file "tool_worktree_coverage_" "" in
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

let rec ensure_dir path =
  if path = "" || path = "." || path = "/" then ()
  else if Sys.file_exists path then ()
  else (
    let parent = Filename.dirname path in
    if parent <> path then ensure_dir parent;
    Unix.mkdir path 0o755)

let run_ok ~cwd cmd =
  let wrapped = Printf.sprintf "cd %s && %s > /dev/null 2>&1" (Filename.quote cwd) cmd in
  let code = Sys.command wrapped in
  if code <> 0 then fail (Printf.sprintf "command failed (%d): %s" code cmd)

let test_dispatch_worktree_create () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_id", `String "task-001"); ("base_branch", `String "main")] in
  try
    match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_worktree_remove () =
  let ctx = make_ctx () in
  let args = `Assoc [("task_id", `String "task-001")] in
  try
    match Tool_worktree.dispatch ctx ~name:"masc_worktree_remove" ~args with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_worktree_list () =
  let ctx = make_ctx () in
  try
    match Tool_worktree.dispatch ctx ~name:"masc_worktree_list" ~args:(`Assoc []) with
    | Some _ -> ()
    | None -> fail "expected Some"
  with _ -> ()

let test_dispatch_unknown_tool () =
  let ctx = make_ctx () in
  match Tool_worktree.dispatch ctx ~name:"masc_unknown" ~args:(`Assoc []) with
  | None -> ()
  | Some _ -> fail "expected None for unknown tool"

(* ============================================================
   Iter-7 (#6527) — agent_name spoof rejection
   ============================================================
   handle_worktree_create used to trust the `agent_name` MCP arg
   verbatim, so agent-A could call
       masc_worktree_create agent_name=agent-B task_id=foo
   and land a worktree inside agent-B's playground. PR #6617 fixed
   the dispatcher to reject any arg value that does not equal
   ctx.agent_name. These cases lock the three-branch decision down
   so a future refactor cannot silently re-introduce the leak. *)

let contains needle haystack =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  if nlen = 0 then true
  else
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

let test_dispatch_worktree_create_spoofed_agent_blocked () =
  let ctx = make_ctx () in
  let args = `Assoc [
    ("agent_name", `String "other-agent");
    ("task_id", `String "task-spoof");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, _) -> fail "spoofed agent_name should have been rejected"
  | Some (false, msg) ->
    check bool "error mentions agent_name mismatch" true
      (contains "agent_name mismatch" msg);
    check bool "error mentions the caller ctx agent" true
      (contains "test-agent" msg);
    check bool "error mentions the spoofed arg value" true
      (contains "other-agent" msg);
    check bool "error explains cross-agent is blocked" true
      (contains "Cross-agent" msg)

let test_dispatch_worktree_create_matching_agent_passes_check () =
  (* When the arg matches ctx.agent_name, the spoof gate must not
     fire. The downstream Coord.worktree_create_r call may still fail
     because the fixture base_path is not a real git repository, so
     we only assert that any error returned is NOT the spoof error. *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("agent_name", `String "test-agent");
    ("task_id", `String "task-match");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (_ok, msg) ->
    check bool "matching agent_name does not trip spoof gate" false
      (contains "agent_name mismatch" msg)

let test_dispatch_worktree_create_empty_agent_falls_back () =
  (* The 9B fallback: empty/missing agent_name arg uses ctx.agent_name
     instead of rejecting. Same assertion shape as the matching case —
     we only prove that the spoof branch is not taken. *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("task_id", `String "task-empty-fallback");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (_ok, msg) ->
    check bool "empty agent_name arg does not trip spoof gate" false
      (contains "agent_name mismatch" msg)

let test_dispatch_worktree_create_whitespace_agent_trimmed () =
  (* Trailing/leading whitespace must be trimmed before the spoof
     check so a 9B model that sends " " by mistake still gets the
     empty-fallback path, not a mismatch rejection. *)
  let ctx = make_ctx () in
  let args = `Assoc [
    ("agent_name", `String "   ");
    ("task_id", `String "task-ws");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (_ok, msg) ->
    check bool "whitespace agent_name trimmed to fallback" false
      (contains "agent_name mismatch" msg)

let test_dispatch_worktree_create_reports_missing_sandbox_clone () =
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run_ok ~cwd:base_path "git init -q -b main";
  let config = Masc_mcp.Coord.default_config base_path in
  ignore (Masc_mcp.Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_worktree.context = { config; agent_name = "test-agent" } in
  let args = `Assoc [
    ("task_id", `String "task-missing-clone");
    ("repo_name", `String "masc-mcp");
    ("base_branch", `String "main");
  ] in
  match Tool_worktree.dispatch ctx ~name:"masc_worktree_create" ~args with
  | None -> fail "dispatch returned None for masc_worktree_create"
  | Some (true, msg) ->
    fail ("expected missing_sandbox_clone error, got success: " ^ msg)
  | Some (false, msg) ->
    if not (contains "missing_sandbox_clone:" msg) then
      fail (Printf.sprintf "expected missing_sandbox_clone in: %s" msg);
    if not (contains "keeper_shell op=git_clone" msg) then
      fail (Printf.sprintf "expected keeper_shell git_clone hint in: %s" msg)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Tool_worktree Coverage" [
    "get_string", [
      test_case "exists" `Quick test_get_string_exists;
      test_case "missing" `Quick test_get_string_missing;
      test_case "base_branch" `Quick test_get_string_base_branch;
      test_case "base_branch_default" `Quick test_get_string_base_branch_default;
    ];
    "context", [
      test_case "creation" `Quick test_context_creation;
    ];
    "dispatch", [
      test_case "worktree_create" `Quick test_dispatch_worktree_create;
      test_case "worktree_remove" `Quick test_dispatch_worktree_remove;
      test_case "worktree_list" `Quick test_dispatch_worktree_list;
      test_case "unknown" `Quick test_dispatch_unknown_tool;
    ];
    "agent_name_spoof", [
      test_case "spoofed agent_name blocked" `Quick
        test_dispatch_worktree_create_spoofed_agent_blocked;
      test_case "matching agent_name passes spoof gate" `Quick
        test_dispatch_worktree_create_matching_agent_passes_check;
      test_case "empty agent_name falls back to ctx" `Quick
        test_dispatch_worktree_create_empty_agent_falls_back;
      test_case "whitespace agent_name trimmed" `Quick
        test_dispatch_worktree_create_whitespace_agent_trimmed;
      test_case "missing sandbox clone is explicit" `Quick
        test_dispatch_worktree_create_reports_missing_sandbox_clone;
    ];
  ]
