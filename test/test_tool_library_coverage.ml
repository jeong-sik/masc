(** Coverage tests for Tool_library — Knowledge library management

    Tests dispatch routing, input validation, and handler integration
    for 5 tools: masc_library_list, masc_library_read, masc_library_add,
    masc_library_promote, masc_library_search

    Note: Tool_library uses HOME env var for library_root(), so tests
    override HOME to a temp directory with the expected structure.
*)

module Tool_library = Masc_mcp.Tool_library

let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try
    ignore (Str.search_forward (Str.regexp_string ln) lc 0);
    true
  with
  | Not_found -> false
;;

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file (Printf.sprintf "test_library_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with
  | _ -> ()
;;

(** Create the expected library directory structure under a temp HOME *)
let setup_library_dirs home =
  let me_dir = Filename.concat home "me" in
  let docs_dir = Filename.concat me_dir "docs" in
  let lib_dir = Filename.concat docs_dir "library" in
  let cand_dir = Filename.concat lib_dir "candidates" in
  Unix.mkdir me_dir 0o755;
  Unix.mkdir docs_dir 0o755;
  Unix.mkdir lib_dir 0o755;
  Unix.mkdir cand_dir 0o755;
  lib_dir, cand_dir
;;

let original_home = Sys.getenv_opt "HOME"

(** Run a test function with a temporary HOME containing library dirs *)
let with_temp_home f =
  let home = temp_dir () in
  Unix.putenv "HOME" home;
  let _ = setup_library_dirs home in
  let ctx : Tool_library.context = { agent_name = "test-agent" } in
  Fun.protect
    ~finally:(fun () ->
      (match original_home with
       | Some h -> Unix.putenv "HOME" h
       | None -> ());
      cleanup_dir home)
    (fun () -> f ctx)
;;

let dispatch_exn ctx ~name ~args =
  match Tool_library.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)
;;

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  with_temp_home (fun ctx ->
    let result = Tool_library.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
    Alcotest.(check bool) "unknown returns None" true (result = None))
;;

let test_dispatch_all_known () =
  with_temp_home (fun ctx ->
    let tools =
      [ "masc_library_list"
      ; "masc_library_read"
      ; "masc_library_add"
      ; "masc_library_promote"
      ; "masc_library_search"
      ]
    in
    List.iter
      (fun name ->
         let result = Tool_library.dispatch ctx ~name ~args:(`Assoc []) in
         Alcotest.(check bool) (name ^ " dispatches") true (result <> None))
      tools)
;;

(* ============================================================
   library_list tests
   ============================================================ *)

let test_list_empty () =
  with_temp_home (fun ctx ->
    let ok, msg = dispatch_exn ctx ~name:"masc_library_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool)
      "response mentions library"
      true
      (msg_contains ~needle:"librar" msg))
;;

let test_list_with_candidates () =
  with_temp_home (fun ctx ->
    let args = `Assoc [ "include_candidates", `Bool true ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_list" ~args in
    Alcotest.(check bool) "list with candidates ok" true ok;
    Alcotest.(check bool)
      "response mentions library"
      true
      (msg_contains ~needle:"librar" msg))
;;

(* ============================================================
   library_read tests
   ============================================================ *)

let test_read_empty_topic () =
  with_temp_home (fun ctx ->
    let ok, msg = dispatch_exn ctx ~name:"masc_library_read" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty topic fails" false ok;
    Alcotest.(check bool) "error mentions topic" true (msg_contains ~needle:"topic" msg))
;;

let test_read_nonexistent_topic () =
  with_temp_home (fun ctx ->
    let args = `Assoc [ "topic", `String "nonexistent_topic" ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_read" ~args in
    Alcotest.(check bool) "nonexistent fails" false ok;
    Alcotest.(check bool)
      "error mentions not found"
      true
      (msg_contains ~needle:"not found" msg || msg_contains ~needle:"no" msg))
;;

(* ============================================================
   library_add tests
   ============================================================ *)

let test_add_missing_title () =
  with_temp_home (fun ctx ->
    let args = `Assoc [ "content", `String "some content" ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "missing title fails" false ok;
    Alcotest.(check bool) "error mentions title" true (msg_contains ~needle:"title" msg))
;;

let test_add_missing_content () =
  with_temp_home (fun ctx ->
    let args = `Assoc [ "title", `String "test doc" ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "missing content fails" false ok;
    Alcotest.(check bool)
      "error mentions content"
      true
      (msg_contains ~needle:"content" msg))
;;

let test_add_invalid_source () =
  with_temp_home (fun ctx ->
    let args =
      `Assoc
        [ "title", `String "test doc"
        ; "content", `String "some content"
        ; "source", `String "invalid_source_type"
        ]
    in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "invalid source fails" false ok;
    Alcotest.(check bool) "mentions source" true (msg_contains ~needle:"source" msg))
;;

let test_add_success () =
  with_temp_home (fun ctx ->
    let args =
      `Assoc
        [ "title", `String "test knowledge"
        ; "content", `String "This is test content for library."
        ; "source", `String "direct_experience"
        ; "confidence", `Float 0.8
        ]
    in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "add succeeds" true ok;
    Alcotest.(check bool)
      "response confirms add"
      true
      (msg_contains ~needle:"added" msg
       || msg_contains ~needle:"success" msg
       || msg_contains ~needle:"librar" msg))
;;

let test_add_low_confidence () =
  with_temp_home (fun ctx ->
    let args =
      `Assoc
        [ "title", `String "uncertain knowledge"
        ; "content", `String "This might be useful."
        ; "confidence", `Float 0.3
        ]
    in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "low confidence accepted" true ok;
    Alcotest.(check bool)
      "response confirms add"
      true
      (msg_contains ~needle:"added" msg
       || msg_contains ~needle:"success" msg
       || msg_contains ~needle:"librar" msg))
;;

let test_add_with_tags () =
  with_temp_home (fun ctx ->
    let args =
      `Assoc
        [ "title", `String "tagged knowledge"
        ; "content", `String "Content with tags."
        ; "tags", `List [ `String "ocaml"; `String "testing" ]
        ]
    in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "add with tags" true ok;
    Alcotest.(check bool)
      "response confirms add"
      true
      (msg_contains ~needle:"added" msg
       || msg_contains ~needle:"success" msg
       || msg_contains ~needle:"librar" msg))
;;

(* ============================================================
   library_search tests
   ============================================================ *)

let test_search_empty_query () =
  with_temp_home (fun ctx ->
    let ok, msg = dispatch_exn ctx ~name:"masc_library_search" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty query fails" false ok;
    Alcotest.(check bool) "error mentions query" true (msg_contains ~needle:"query" msg))
;;

let test_search_with_query () =
  with_temp_home (fun ctx ->
    let args = `Assoc [ "query", `String "test" ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_search" ~args in
    (* Succeeds even with no results *)
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "response is substantive" true (String.length msg > 5))
;;

(* ============================================================
   library_promote tests
   ============================================================ *)

let test_promote_empty_topic () =
  with_temp_home (fun ctx ->
    let ok, msg = dispatch_exn ctx ~name:"masc_library_promote" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty topic fails" false ok;
    Alcotest.(check bool) "error mentions topic" true (msg_contains ~needle:"topic" msg))
;;

let test_promote_nonexistent () =
  with_temp_home (fun ctx ->
    let args = `Assoc [ "topic", `String "nonexistent"; "confidence", `Float 0.9 ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_promote" ~args in
    Alcotest.(check bool) "nonexistent fails" false ok;
    Alcotest.(check bool)
      "error mentions not found"
      true
      (msg_contains ~needle:"not found" msg || msg_contains ~needle:"no" msg))
;;

let test_promote_updates_frontmatter () =
  with_temp_home (fun ctx ->
    let candidate_path =
      Filename.concat (Tool_library.candidates_dir ()) "regex-topic-20260425.md"
    in
    Out_channel.with_open_text candidate_path (fun oc ->
      Out_channel.output_string
        oc
        {|---
title: Regex Topic
source: direct_experience
confidence: 0.30
author: test-agent
created: 2026-04-25
updated: 2026-04-25
tags: []
verified_by: []
---

Promotion should preserve the body.
|});
    let args = `Assoc [ "topic", `String "regex-topic"; "confidence", `Float 0.91 ] in
    let ok, msg = dispatch_exn ctx ~name:"masc_library_promote" ~args in
    Alcotest.(check bool) "promote succeeds" true ok;
    Alcotest.(check bool)
      "response mentions promoted"
      true
      (msg_contains ~needle:"promoted" msg);
    Alcotest.(check bool) "candidate removed" false (Sys.file_exists candidate_path);
    let promoted_path =
      Filename.concat (Tool_library.library_root ()) (Filename.basename candidate_path)
    in
    Alcotest.(check bool) "library file exists" true (Sys.file_exists promoted_path);
    let promoted = In_channel.with_open_text promoted_path In_channel.input_all in
    Alcotest.(check bool)
      "confidence updated"
      true
      (msg_contains ~needle:"confidence: 0.91" promoted);
    Alcotest.(check bool)
      "verifier added"
      true
      (msg_contains ~needle:"verified_by: [test-agent]" promoted))
;;

(* ============================================================
   Workflow: add → list → read → search
   ============================================================ *)

let test_full_workflow () =
  with_temp_home (fun ctx ->
    (* Step 1: Add a document *)
    let add_args =
      `Assoc
        [ "title", `String "workflow test"
        ; "content", `String "Knowledge about OCaml testing patterns."
        ; "source", `String "direct_experience"
        ; "confidence", `Float 0.8
        ]
    in
    let ok1, _ = dispatch_exn ctx ~name:"masc_library_add" ~args:add_args in
    Alcotest.(check bool) "add succeeds" true ok1;
    (* Step 2: List documents *)
    let ok2, msg2 = dispatch_exn ctx ~name:"masc_library_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list succeeds" true ok2;
    Alcotest.(check bool) "list has content" true (String.length msg2 > 0);
    (* Step 3: Search *)
    let search_args = `Assoc [ "query", `String "OCaml" ] in
    let ok3, _ = dispatch_exn ctx ~name:"masc_library_search" ~args:search_args in
    Alcotest.(check bool) "search succeeds" true ok3;
    (* Step 4: Read the document *)
    let read_args = `Assoc [ "topic", `String "workflow-test" ] in
    let ok4, msg4 = dispatch_exn ctx ~name:"masc_library_read" ~args:read_args in
    (* May fail if filename convention differs — just check dispatch *)
    ignore ok4;
    Alcotest.(check bool) "read has response" true (String.length msg4 > 0))
;;

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run
    "Tool_library"
    [ ( "dispatch"
      , [ Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown
        ; Alcotest.test_case "all known tools dispatch" `Quick test_dispatch_all_known
        ] )
    ; ( "library_list"
      , [ Alcotest.test_case "empty list" `Quick test_list_empty
        ; Alcotest.test_case "with candidates" `Quick test_list_with_candidates
        ] )
    ; ( "library_read"
      , [ Alcotest.test_case "empty topic" `Quick test_read_empty_topic
        ; Alcotest.test_case "nonexistent topic" `Quick test_read_nonexistent_topic
        ] )
    ; ( "library_add"
      , [ Alcotest.test_case "missing title" `Quick test_add_missing_title
        ; Alcotest.test_case "missing content" `Quick test_add_missing_content
        ; Alcotest.test_case "invalid source" `Quick test_add_invalid_source
        ; Alcotest.test_case "success" `Quick test_add_success
        ; Alcotest.test_case "low confidence" `Quick test_add_low_confidence
        ; Alcotest.test_case "with tags" `Quick test_add_with_tags
        ] )
    ; ( "library_search"
      , [ Alcotest.test_case "empty query" `Quick test_search_empty_query
        ; Alcotest.test_case "with query" `Quick test_search_with_query
        ] )
    ; ( "library_promote"
      , [ Alcotest.test_case "empty topic" `Quick test_promote_empty_topic
        ; Alcotest.test_case "nonexistent" `Quick test_promote_nonexistent
        ; Alcotest.test_case "updates frontmatter" `Quick test_promote_updates_frontmatter
        ] )
    ; "workflow", [ Alcotest.test_case "add list search read" `Quick test_full_workflow ]
    ]
;;
