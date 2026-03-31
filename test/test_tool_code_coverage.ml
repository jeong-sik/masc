(** Coverage tests for Tool_code — Code search, symbols, and file reading

    Tests dispatch routing, input validation, and error paths
    for 3 tools: masc_code_search, masc_code_symbols, masc_code_read
*)

module Tool_code = Masc_mcp.Tool_code
module Tool_code_write = Masc_mcp.Tool_code_write
module Room = Masc_mcp.Room

(* msg_contains: case-insensitive substring check *)
let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try ignore (Str.search_forward (Str.regexp_string ln) lc 0); true
  with Not_found -> false

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file
    (Printf.sprintf "test_code_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let init_git_repo dir =
  let cmd = Printf.sprintf "git -C %s init -q" (Filename.quote dir) in
  match Sys.command cmd with
  | 0 -> ()
  | code -> failwith (Printf.sprintf "git init failed with exit %d" code)

let make_ctx () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_code.context = { config; agent_name = "test-agent" } in
  (ctx, base_dir)

let make_git_ctx () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  init_git_repo base_dir;
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_code.context = { config; agent_name = "test-agent" } in
  (ctx, base_dir)

let make_git_write_ctx () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  init_git_repo base_dir;
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_code_write.context = { config; agent_name = "test-agent" } in
  (ctx, base_dir)

let dispatch_exn ctx ~name ~args =
  match Tool_code.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_code.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_code_search () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_code.dispatch ctx ~name:"masc_code_search" ~args:(`Assoc []) in
  Alcotest.(check bool) "code_search dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_code_symbols () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_code.dispatch ctx ~name:"masc_code_symbols" ~args:(`Assoc []) in
  Alcotest.(check bool) "code_symbols dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_code_read () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_code.dispatch ctx ~name:"masc_code_read" ~args:(`Assoc []) in
  Alcotest.(check bool) "code_read dispatches" true (result <> None);
  cleanup_dir base_dir

(* ============================================================
   code_search validation
   ============================================================ *)

let test_code_search_empty_query () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_search" ~args:(`Assoc []) in
  Alcotest.(check bool) "empty query fails" false ok;
  Alcotest.(check bool) "has error msg" true (String.length msg > 0);
  cleanup_dir base_dir

let test_code_search_with_query () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("query", `String "test_pattern")] in
  let (_, msg) = dispatch_exn ctx ~name:"masc_code_search" ~args in
  (* May fail (no rg, no git root) but should return a response *)
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_code_search_with_options () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("query", `String "fn");
    ("path", `String ".");
    ("file_pattern", `String "*.ml");
    ("case_insensitive", `Bool true);
    ("max_results", `Int 10);
  ] in
  let (_, msg) = dispatch_exn ctx ~name:"masc_code_search" ~args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   code_read validation
   ============================================================ *)

let test_code_read_no_path () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_read" ~args:(`Assoc []) in
  Alcotest.(check bool) "no path fails" false ok;
  Alcotest.(check bool) "has error msg" true (String.length msg > 0);
  cleanup_dir base_dir

let test_code_read_path_traversal () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("path", `String "../../../etc/passwd")] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_read" ~args in
  Alcotest.(check bool) "path traversal blocked" false ok;
  (* validate_path rejects: either "Path traversal" or "Not in a git repository" *)
  let has_security_msg =
    msg_contains ~needle:"traversal" msg ||
    msg_contains ~needle:"git" msg in
  Alcotest.(check bool) "error mentions security boundary" true has_security_msg;
  cleanup_dir base_dir

let test_code_read_with_offset_limit () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("path", `String "test.ml");
    ("offset", `Int 10);
    ("limit", `Int 20);
  ] in
  let (_, msg) = dispatch_exn ctx ~name:"masc_code_read" ~args in
  (* Will fail (file doesn't exist) but dispatch + validation should work *)
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_code_read_blocks_sibling_prefix_escape () =
  let ctx, base_dir = make_git_ctx () in
  let sibling_dir = base_dir ^ "-sibling" in
  let sibling_file = Filename.concat sibling_dir "proof.txt" in
  Unix.mkdir sibling_dir 0o755;
  Out_channel.with_open_text sibling_file (fun oc ->
    output_string oc "outside-root-proof\n");
  let args = `Assoc [("path", `String sibling_file)] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_read" ~args in
  Alcotest.(check bool) "sibling prefix escape blocked" false ok;
  Alcotest.(check bool) "error mentions traversal" true
    (msg_contains ~needle:"traversal" msg);
  cleanup_dir sibling_dir;
  cleanup_dir base_dir

let test_code_write_blocks_worktree_escape () =
  let ctx, base_dir = make_git_write_ctx () in
  let escape_target_dir = Filename.concat (Filename.dirname base_dir) "code_write_escape_target" in
  let escape_target_file = Filename.concat escape_target_dir "proof.txt" in
  cleanup_dir escape_target_dir;
  let args = `Assoc [
    ("path", `String ".worktrees/../../code_write_escape_target/proof.txt");
    ("content", `String "escape\n");
    ("create_dirs", `Bool true);
  ] in
  let (ok, msg) = Tool_code_write.handle_code_write ctx args in
  Alcotest.(check bool) "worktree escape blocked" false ok;
  Alcotest.(check bool) "error mentions write restriction" true
    (msg_contains ~needle:"restricted" msg || msg_contains ~needle:"traversal" msg);
  Alcotest.(check bool) "escape target not created" false (Sys.file_exists escape_target_file);
  cleanup_dir escape_target_dir;
  cleanup_dir base_dir

(* ============================================================
   code_symbols validation
   ============================================================ *)

let test_code_symbols_empty () =
  let ctx, base_dir = make_ctx () in
  let (_, msg) = dispatch_exn ctx ~name:"masc_code_symbols" ~args:(`Assoc []) in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_code_symbols_with_path () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("path", `String ".")] in
  let (_, msg) = dispatch_exn ctx ~name:"masc_code_symbols" ~args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_code" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "code_search dispatches" `Quick test_dispatch_code_search;
      Alcotest.test_case "code_symbols dispatches" `Quick test_dispatch_code_symbols;
      Alcotest.test_case "code_read dispatches" `Quick test_dispatch_code_read;
    ]);
    ("code_search", [
      Alcotest.test_case "empty query" `Quick test_code_search_empty_query;
      Alcotest.test_case "with query" `Quick test_code_search_with_query;
      Alcotest.test_case "with options" `Quick test_code_search_with_options;
    ]);
    ("code_read", [
      Alcotest.test_case "no path" `Quick test_code_read_no_path;
      Alcotest.test_case "path traversal" `Quick test_code_read_path_traversal;
      Alcotest.test_case "offset and limit" `Quick test_code_read_with_offset_limit;
      Alcotest.test_case "blocks sibling prefix escape" `Quick
        test_code_read_blocks_sibling_prefix_escape;
    ]);
    ("code_write", [
      Alcotest.test_case "blocks worktree escape" `Quick
        test_code_write_blocks_worktree_escape;
    ]);
    ("code_symbols", [
      Alcotest.test_case "empty args" `Quick test_code_symbols_empty;
      Alcotest.test_case "with path" `Quick test_code_symbols_with_path;
    ]);
  ]
