(** Coverage tests for Tool_code — Code search, symbols, and file reading

    Tests dispatch routing, input validation, and error paths
    for 3 tools: masc_code_search, masc_code_symbols, masc_code_read
*)

module Tool_code = Masc_mcp.Tool_code
module Coord = Masc_mcp.Coord

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

let write_text_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let run_shell_ok ~cwd cmd =
  let quoted_cwd = Filename.quote cwd in
  let rc = Sys.command (Printf.sprintf "cd %s && %s" quoted_cwd cmd) in
  Alcotest.(check int) ("shell command: " ^ cmd) 0 rc

let make_ctx_in_dir base_dir =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_code.context = { config; agent_name = "test-agent" } in
  ctx

let make_ctx () =
  let base_dir = temp_dir () in
  let ctx = make_ctx_in_dir base_dir in
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
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_search" ~args in
  Alcotest.(check bool) "missing path fails" false ok;
  Alcotest.(check bool) "mentions path required" true (msg_contains ~needle:"path required" msg);
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

let test_code_search_with_file_pattern_finds_matches () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      run_shell_ok ~cwd:base_dir "git init -q -b main";
      run_shell_ok ~cwd:base_dir "git config user.email test@example.com";
      run_shell_ok ~cwd:base_dir "git config user.name test";
      write_text_file (Filename.concat base_dir "match.ml")
        "let mascot_needle = 1\n";
      write_text_file (Filename.concat base_dir "ignore.md")
        "mascot_needle should not be matched\n";
      let ctx = make_ctx_in_dir base_dir in
      let args = `Assoc [
        ("query", `String "mascot_needle");
        ("path", `String ".");
        ("file_pattern", `String "*.ml");
        ("case_insensitive", `Bool true);
        ("max_results", `Int 10);
      ] in
      let (ok, msg) = dispatch_exn ctx ~name:"masc_code_search" ~args in
      Alcotest.(check bool) "search succeeds" true ok;
      let result = Yojson.Safe.from_string msg in
      let module U = Yojson.Safe.Util in
      let count = U.(result |> member "count" |> to_int) in
      Alcotest.(check int) "finds one ml match" 1 count;
      let first = U.(result |> member "results" |> index 0) in
      let matched_path = U.(first |> member "path" |> to_string) in
      Alcotest.(check string) "matched file basename" "match.ml"
        (Filename.basename matched_path))

let test_code_search_treats_dash_prefixed_query_as_literal () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      run_shell_ok ~cwd:base_dir "git init -q -b main";
      run_shell_ok ~cwd:base_dir "git config user.email test@example.com";
      run_shell_ok ~cwd:base_dir "git config user.name test";
      write_text_file (Filename.concat base_dir "sample.txt")
        "--help should be searched literally\n";
      let ctx = make_ctx_in_dir base_dir in
      let args = `Assoc [
        ("query", `String "--help");
        ("path", `String ".");
        ("case_insensitive", `Bool true);
        ("max_results", `Int 10);
      ] in
      let (ok, msg) = dispatch_exn ctx ~name:"masc_code_search" ~args in
      Alcotest.(check bool) "search succeeds" true ok;
      let result = Yojson.Safe.from_string msg in
      let module U = Yojson.Safe.Util in
      let count = U.(result |> member "count" |> to_int) in
      Alcotest.(check int) "finds dash-prefixed literal" 1 count)

let test_code_search_schema_requires_path () =
  let schema =
    List.find_opt (fun (schema : Masc_domain.tool_schema) ->
      String.equal schema.name "masc_code_search")
      Tool_code.schemas
  in
  match schema with
  | None -> Alcotest.fail "masc_code_search schema missing"
  | Some schema ->
      let module U = Yojson.Safe.Util in
      let required =
        schema.input_schema |> U.member "required" |> U.to_list
        |> List.filter_map (function `String value -> Some value | _ -> None)
      in
      Alcotest.(check bool) "query required" true (List.mem "query" required);
      Alcotest.(check bool) "path required" true (List.mem "path" required)

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
  let has_security_msg =
    msg_contains ~needle:"traversal" msg ||
    msg_contains ~needle:"git" msg in
  Alcotest.(check bool) "error mentions security boundary" true has_security_msg;
  cleanup_dir base_dir

(* Regression: dotdot hidden inside a valid-looking prefix must be caught *)
let test_code_read_dotdot_inside_prefix () =
  let ctx, base_dir = make_ctx () in
  let attack_path = ".worktrees/../../escape/proof.txt" in
  let args = `Assoc [("path", `String attack_path)] in
  let (ok, _msg) = dispatch_exn ctx ~name:"masc_code_read" ~args in
  Alcotest.(check bool) "dotdot inside prefix blocked" false ok;
  cleanup_dir base_dir

let test_code_read_absolute_sibling () =
  let ctx, base_dir = make_ctx () in
  let sibling = Filename.concat (Filename.dirname base_dir) "sibling" in
  let args = `Assoc [("path", `String sibling)] in
  let (ok, _msg) = dispatch_exn ctx ~name:"masc_code_read" ~args in
  Alcotest.(check bool) "absolute sibling path blocked" false ok;
  cleanup_dir base_dir

let test_code_read_null_byte () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("path", `String "test.ml\x00../../etc/passwd")] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_code_read" ~args in
  Alcotest.(check bool) "null byte blocked" false ok;
  Alcotest.(check bool) "error mentions null" true (msg_contains ~needle:"null" msg);
  cleanup_dir base_dir

let test_normalize_path_resolves_dotdot () =
  let check desc input expected =
    let result = Tool_code.normalize_path input in
    Alcotest.(check string) desc expected result
  in
  check "simple dotdot" "/a/b/../c" "/a/c";
  check "multiple dotdot" "/a/b/c/../../d" "/a/d";
  check "dotdot at root" "/a/../../../x" "/x";
  check "dot removal" "/a/./b/./c" "/a/b/c";
  check "trailing slash" "/a/b/" "/a/b"

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
      Alcotest.test_case "with query requires path" `Quick test_code_search_with_query;
      Alcotest.test_case "with options" `Quick test_code_search_with_options;
      Alcotest.test_case "file pattern matches files" `Quick
        test_code_search_with_file_pattern_finds_matches;
      Alcotest.test_case "dash-prefixed query stays literal" `Quick
        test_code_search_treats_dash_prefixed_query_as_literal;
      Alcotest.test_case "schema requires path" `Quick
        test_code_search_schema_requires_path;
    ]);
    ("code_read", [
      Alcotest.test_case "no path" `Quick test_code_read_no_path;
      Alcotest.test_case "path traversal" `Quick test_code_read_path_traversal;
      Alcotest.test_case "dotdot inside prefix" `Quick test_code_read_dotdot_inside_prefix;
      Alcotest.test_case "absolute sibling path" `Quick test_code_read_absolute_sibling;
      Alcotest.test_case "null byte injection" `Quick test_code_read_null_byte;
      Alcotest.test_case "offset and limit" `Quick test_code_read_with_offset_limit;
    ]);
    ("normalize_path", [
      Alcotest.test_case "resolves dotdot" `Quick test_normalize_path_resolves_dotdot;
    ]);
    ("code_symbols", [
      Alcotest.test_case "empty args" `Quick test_code_symbols_empty;
      Alcotest.test_case "with path" `Quick test_code_symbols_with_path;
    ]);
  ]
