(** Coverage tests for Tool_social — MCP tool handlers for social features

    Tests dispatch routing, input validation, and handler integration
    for all 6 social tools:
    - masc_post_create, masc_post_list, masc_post_get
    - masc_comment_add, masc_comment_list
    - masc_vote
*)

module Tool_social = Masc_mcp.Tool_social
module Room = Masc_mcp.Room
module Room_utils = Room_utils

(** Case-insensitive substring check for error message assertions. *)
let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try ignore (Str.search_forward (Str.regexp_string ln) lc 0); true
  with Not_found -> false

let temp_dir () =
  let dir = Filename.temp_file "test_tool_social_" "" in
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

let make_ctx () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_social.context = { config; agent_name = "test-agent" } in
  (ctx, base_dir)

let dispatch_exn ctx ~name ~args =
  match Tool_social.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown_tool () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_social.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_all_known_tools () =
  let ctx, base_dir = make_ctx () in
  let tools = [
    "masc_post_create"; "masc_post_list"; "masc_post_get";
    "masc_comment_add"; "masc_comment_list"; "masc_vote"
  ] in
  List.iter (fun name ->
    let result = Tool_social.dispatch ctx ~name ~args:(`Assoc []) in
    Alcotest.(check bool) (name ^ " dispatches") true (result <> None)
  ) tools;
  cleanup_dir base_dir

(* ============================================================
   Input validation tests
   ============================================================ *)

let test_post_create_empty_content () =
  let ctx, base_dir = make_ctx () in
  let (ok, _msg) = dispatch_exn ctx ~name:"masc_post_create" ~args:(`Assoc []) in
  Alcotest.(check bool) "empty content fails" false ok;
  cleanup_dir base_dir

let test_post_create_content_too_long () =
  let ctx, base_dir = make_ctx () in
  let long_content = String.make 10_001 'x' in
  let args = `Assoc [("content", `String long_content)] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_post_create" ~args in
  Alcotest.(check bool) "too-long content fails" false ok;
  Alcotest.(check bool) "error mentions length" true (msg_contains ~needle:"too long" msg);
  cleanup_dir base_dir

let test_post_create_invalid_author () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("content", `String "hello");
    ("author", `String "invalid author!");
  ] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_post_create" ~args in
  Alcotest.(check bool) "invalid author fails" false ok;
  Alcotest.(check bool) "error mentions author" true (msg_contains ~needle:"author" msg);
  cleanup_dir base_dir

let test_comment_add_empty_post_id () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("content", `String "a comment")] in
  let (ok, _msg) = dispatch_exn ctx ~name:"masc_comment_add" ~args in
  Alcotest.(check bool) "empty post_id fails" false ok;
  cleanup_dir base_dir

let test_vote_empty_target_id () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [] in
  let (ok, _msg) = dispatch_exn ctx ~name:"masc_vote" ~args in
  Alcotest.(check bool) "empty target_id fails" false ok;
  cleanup_dir base_dir

let test_validate_id_too_long () =
  let ctx, base_dir = make_ctx () in
  let long_id = String.make 129 'a' in
  let args = `Assoc [("post_id", `String long_id)] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_post_get" ~args in
  Alcotest.(check bool) "too-long id fails" false ok;
  Alcotest.(check bool) "error mentions too long" true (msg_contains ~needle:"too long" msg);
  cleanup_dir base_dir

let test_validate_id_bad_chars () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("post_id", `String "bad/id!")] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_post_get" ~args in
  Alcotest.(check bool) "bad chars fails" false ok;
  Alcotest.(check bool) "error mentions alphanumeric" true (msg_contains ~needle:"alphanumeric" msg);
  cleanup_dir base_dir

(* ============================================================
   Full workflow: create → list → get → comment → vote
   ============================================================ *)

let test_post_create_success () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("content", `String "Test post content");
    ("submolt", `String "general");
  ] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_post_create" ~args in
  Alcotest.(check bool) "post created" true ok;
  Alcotest.(check bool) "result mentions Post" true (msg_contains ~needle:"post created" msg);
  cleanup_dir base_dir

let test_post_list_empty () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [] in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_post_list" ~args in
  Alcotest.(check bool) "list ok" true ok;
  Alcotest.(check bool) "empty result" true (msg_contains ~needle:"no posts" msg);
  cleanup_dir base_dir

let test_post_list_with_submolt_filter () =
  let ctx, base_dir = make_ctx () in
  (* Create a post with submolt *)
  let create_args = `Assoc [
    ("content", `String "Filtered post");
    ("submolt", `String "tech");
  ] in
  let (ok1, _) = dispatch_exn ctx ~name:"masc_post_create" ~args:create_args in
  Alcotest.(check bool) "post created" true ok1;
  (* List with submolt filter *)
  let list_args = `Assoc [("submolt", `String "tech")] in
  let (ok2, msg) = dispatch_exn ctx ~name:"masc_post_list" ~args:list_args in
  Alcotest.(check bool) "filtered list ok" true ok2;
  Alcotest.(check bool) "result mentions tech" true (msg_contains ~needle:"[tech]" msg);
  cleanup_dir base_dir

let test_full_workflow () =
  let ctx, base_dir = make_ctx () in
  (* Step 1: Create post *)
  let create_args = `Assoc [("content", `String "Workflow test post")] in
  let (ok1, result1) = dispatch_exn ctx ~name:"masc_post_create" ~args:create_args in
  Alcotest.(check bool) "post created" true ok1;
  (* Extract post_id from the creation result *)
  let post_id_str =
    let idx = try String.index result1 '{' with Not_found -> 0 in
    let json = Yojson.Safe.from_string (String.sub result1 idx (String.length result1 - idx)) in
    json |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "post has id" true (String.length post_id_str > 0);
  (* Step 2: Get post *)
  let get_args = `Assoc [("post_id", `String post_id_str)] in
  let (ok2, _msg2) = dispatch_exn ctx ~name:"masc_post_get" ~args:get_args in
  Alcotest.(check bool) "post retrieved" true ok2;
  (* Step 3: Add comment *)
  let comment_args = `Assoc [
    ("post_id", `String post_id_str);
    ("content", `String "Nice post!");
  ] in
  let (ok3, _msg3) = dispatch_exn ctx ~name:"masc_comment_add" ~args:comment_args in
  Alcotest.(check bool) "comment added" true ok3;
  (* Step 4: List comments *)
  let comment_list_args = `Assoc [("post_id", `String post_id_str)] in
  let (ok4, msg4) = dispatch_exn ctx ~name:"masc_comment_list" ~args:comment_list_args in
  Alcotest.(check bool) "comments listed" true ok4;
  Alcotest.(check bool) "comment content present" true (msg_contains ~needle:"nice post" msg4);
  (* Step 5: Vote on post *)
  let vote_args = `Assoc [
    ("target_id", `String post_id_str);
    ("target_type", `String "post");
    ("direction", `String "up");
  ] in
  let (ok5, msg5) = dispatch_exn ctx ~name:"masc_vote" ~args:vote_args in
  Alcotest.(check bool) "vote ok" true ok5;
  Alcotest.(check bool) "vote result" true (msg_contains ~needle:"+1" msg5);
  cleanup_dir base_dir

let test_vote_downvote () =
  let ctx, base_dir = make_ctx () in
  (* Create a post first *)
  let create_args = `Assoc [("content", `String "Downvote target")] in
  let (ok1, result1) = dispatch_exn ctx ~name:"masc_post_create" ~args:create_args in
  Alcotest.(check bool) "post created" true ok1;
  let post_id =
    let idx = try String.index result1 '{' with Not_found -> 0 in
    let json = Yojson.Safe.from_string (String.sub result1 idx (String.length result1 - idx)) in
    json |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string
  in
  let vote_args = `Assoc [
    ("target_id", `String post_id);
    ("direction", `String "down");
  ] in
  let (ok2, msg2) = dispatch_exn ctx ~name:"masc_vote" ~args:vote_args in
  Alcotest.(check bool) "downvote ok" true ok2;
  Alcotest.(check bool) "downvote result" true (msg_contains ~needle:"-1" msg2);
  cleanup_dir base_dir

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_social" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown_tool;
      Alcotest.test_case "all known tools dispatch" `Quick test_dispatch_all_known_tools;
    ]);
    ("validation", [
      Alcotest.test_case "post_create empty content" `Quick test_post_create_empty_content;
      Alcotest.test_case "post_create content too long" `Quick test_post_create_content_too_long;
      Alcotest.test_case "post_create invalid author" `Quick test_post_create_invalid_author;
      Alcotest.test_case "comment_add empty post_id" `Quick test_comment_add_empty_post_id;
      Alcotest.test_case "vote empty target_id" `Quick test_vote_empty_target_id;
      Alcotest.test_case "validate_id too long" `Quick test_validate_id_too_long;
      Alcotest.test_case "validate_id bad chars" `Quick test_validate_id_bad_chars;
    ]);
    ("workflow", [
      Alcotest.test_case "post create success" `Quick test_post_create_success;
      Alcotest.test_case "post list empty" `Quick test_post_list_empty;
      Alcotest.test_case "post list with submolt" `Quick test_post_list_with_submolt_filter;
      Alcotest.test_case "full workflow" `Quick test_full_workflow;
      Alcotest.test_case "downvote" `Quick test_vote_downvote;
    ]);
  ]
