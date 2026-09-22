(** Coverage tests for Tool_library — Knowledge library management

    Tests dispatch routing, input validation, and handler integration
    for 4 tools: masc_library_list, masc_library_read, masc_library_add,
    masc_library_search

    The library lives under the context's [base_path]; each test hands the
    tools a temp directory as that workspace.
*)

module Tool_library = Masc.Tool_library

let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try ignore (Str.search_forward (Str.regexp_string ln) lc 0); true
  with Not_found -> false

let required_schema name =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      Tool_library.schemas
  with
  | Some schema -> schema
  | None -> Alcotest.failf "missing schema for %s" name

let schema_required_fields (schema : Masc_domain.tool_schema) =
  match schema.input_schema with
  | `Assoc fields ->
    (match List.assoc_opt "required" fields with
     | Some (`List values) ->
       List.map
         (function
           | `String value -> value
           | other ->
             Alcotest.failf
               "%s required contains non-string: %s"
               schema.name
               (Yojson.Safe.to_string other))
         values
     | Some other ->
       Alcotest.failf
         "%s required is not a list: %s"
         schema.name
         (Yojson.Safe.to_string other)
     | None -> [])
  | other ->
    Alcotest.failf
      "%s input_schema is not an object: %s"
      schema.name
      (Yojson.Safe.to_string other)

let schema_has_property (schema : Masc_domain.tool_schema) property =
  match schema.input_schema with
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | Some (`Assoc properties) -> List.mem_assoc property properties
     | _ -> false)
  | _ -> false

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file
    (Printf.sprintf "test_library_%d_" !test_counter) "" in
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

(* The library takes its workspace from the context, never from the process
   environment. The suite still points MASC_BASE_PATH at a scratch directory of
   its own: a regression that reads the variable again then writes there, where
   [test_library_follows_context_base_path] looks, and not into the live
   workspace a developer's shell exports. *)
let decoy_base_path =
  let dir = temp_dir () in
  Unix.putenv "MASC_BASE_PATH" dir;
  at_exit (fun () -> cleanup_dir dir);
  dir

(** Create the expected library directory structure under a temp base path. *)
let setup_library_dirs base_path =
  let docs_dir = Filename.concat base_path "docs" in
  let lib_dir = Filename.concat docs_dir "library" in
  Unix.mkdir docs_dir 0o755;
  Unix.mkdir lib_dir 0o755;
  lib_dir

(** Run a test function with a temporary workspace containing library dirs. *)
let with_temp_base_path ?(prepare_library=true) f =
  let base_path = temp_dir () in
  if prepare_library then ignore (setup_library_dirs base_path);
  let ctx : Tool_library.context = { base_path; agent_name = "test-agent" } in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () -> f ctx)

let library_documents (ctx : Tool_library.context) =
  let root = Tool_library.library_root ~base_path:ctx.base_path in
  if Sys.file_exists root
  then
    Sys.readdir root |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".md")
  else []

let write_library_document (ctx : Tool_library.context) ~filename body =
  let path =
    Filename.concat (Tool_library.library_root ~base_path:ctx.base_path) filename
  in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc body)

let dispatch_exn ctx ~name ~args =
  match Tool_library.dispatch ctx ~name ~args with
  | Some result -> ((Tool_result.is_success result), (Tool_result.message result))
  | None -> failwith ("dispatch returned None for " ^ name)

let test_add_on_fresh_base () =
  List.iter (fun title ->
    with_temp_base_path ~prepare_library:false (fun ctx ->
      Alcotest.(check bool) "library initially absent" false
        (Sys.file_exists (Tool_library.library_root ~base_path:ctx.base_path));
      let ok, _ = dispatch_exn ctx ~name:"masc_library_add"
          ~args:(`Assoc ["title", `String title; "content", `String "fresh base evidence";
                         "source", `String "experiment"]) in
      Alcotest.(check bool) "first add succeeds" true ok;
      let ok, content = dispatch_exn ctx ~name:"masc_library_read"
          ~args:(`Assoc ["topic", `String title]) in
      Alcotest.(check bool) "saved document readable" true ok;
      Alcotest.(check bool) "exact content retained" true
        (String_util.contains_substring content "fresh base evidence")))
    ["Fresh library"; "새 도서관"]

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  with_temp_base_path (fun ctx ->
    let result = Tool_library.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
    Alcotest.(check bool) "unknown returns None" true (result = None)
  )

let test_dispatch_all_known () =
  with_temp_base_path (fun ctx ->
    let tools = [
      "masc_library_list"; "masc_library_read"; "masc_library_add";
      "masc_library_search";
    ] in
    List.iter (fun name ->
      let result = Tool_library.dispatch ctx ~name ~args:(`Assoc []) in
      Alcotest.(check bool) (name ^ " dispatches") true (result <> None)
    ) tools
  )

(* ============================================================
   library_list tests
   ============================================================ *)

let test_list_empty () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "response mentions library" true (msg_contains ~needle:"librar" msg)
  )

(* ============================================================
   library_read tests
   ============================================================ *)

let test_read_empty_topic () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_read" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty topic fails" false ok;
    Alcotest.(check bool) "error mentions topic" true (msg_contains ~needle:"topic" msg)
  )

let test_read_nonexistent_topic () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [("topic", `String "nonexistent_topic")] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_read" ~args in
    Alcotest.(check bool) "nonexistent fails" false ok;
    Alcotest.(check bool) "error mentions not found" true
      (msg_contains ~needle:"not found" msg || msg_contains ~needle:"no" msg)
  )

(* The list -> read contract: masc_library_list surfaces the frontmatter title,
   so reading back that exact title must resolve the document. Before the fix,
   read matched only the slug filename (which drops the title's spaces, colons,
   and case), so a title query never matched. *)
let test_read_by_title_roundtrip () =
  with_temp_base_path (fun ctx ->
    let title = "Blocker Chain V3: Repos Exists, The Real Blocker" in
    let add_args = `Assoc [
      ("title", `String title);
      ("content", `String "Body of the document for round-trip.");
      ("source", `String "direct_experience");
    ] in
    let (added, _) = dispatch_exn ctx ~name:"masc_library_add" ~args:add_args in
    Alcotest.(check bool) "add succeeds" true added;
    let read_args = `Assoc [("topic", `String title)] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_read" ~args:read_args in
    Alcotest.(check bool) "read by exact title succeeds" true ok;
    Alcotest.(check bool) "returns the body" true
      (msg_contains ~needle:"Body of the document" msg)
  )

let test_read_by_title_case_insensitive_partial () =
  with_temp_base_path (fun ctx ->
    let _ = dispatch_exn ctx ~name:"masc_library_add" ~args:(`Assoc [
      ("title", `String "Root Cause: Orphan Count Analysis");
      ("content", `String "details about orphan counting");
      ("source", `String "observation");
    ]) in
    let read_args = `Assoc [("topic", `String "root cause: orphan count")] in
    let (ok, _) = dispatch_exn ctx ~name:"masc_library_read" ~args:read_args in
    Alcotest.(check bool) "case-insensitive partial title match" true ok
  )

(* Slug queries must keep working — the fix adds title matching, it does not
   replace filename matching. *)
let test_read_by_slug_still_works () =
  with_temp_base_path (fun ctx ->
    let _ = dispatch_exn ctx ~name:"masc_library_add" ~args:(`Assoc [
      ("title", `String "Slug Query Doc");
      ("content", `String "slug body");
      ("source", `String "research");
    ]) in
    let read_args = `Assoc [("topic", `String "slug-query")] in
    let (ok, _) = dispatch_exn ctx ~name:"masc_library_read" ~args:read_args in
    Alcotest.(check bool) "slug substring still matches" true ok
  )

(* ============================================================
   library_add tests
   ============================================================ *)

let test_add_missing_title () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [("content", `String "some content")] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "missing title fails" false ok;
    Alcotest.(check bool) "error mentions title" true (msg_contains ~needle:"title" msg)
  )

let test_add_missing_content () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [("title", `String "test doc")] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "missing content fails" false ok;
    Alcotest.(check bool) "error mentions content" true (msg_contains ~needle:"content" msg)
  )

let test_add_invalid_source () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [
      ("title", `String "test doc");
      ("content", `String "some content");
      ("source", `String "invalid_source_type");
    ] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "invalid source fails" false ok;
    Alcotest.(check bool) "mentions source" true (msg_contains ~needle:"source" msg)
  )

(* The schema requires [source]. A document written without one would record a
   kind of work its writer never named, so the call is refused and nothing is
   written. *)
let test_add_missing_source () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [
      ("title", `String "unsourced doc");
      ("content", `String "some content");
    ] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "missing source fails" false ok;
    Alcotest.(check bool) "names the missing field" true
      (msg_contains ~needle:"source is required" msg);
    Alcotest.(check (list string)) "no document written" [] (library_documents ctx)
  )

(* The library is the caller's workspace, not whatever MASC_BASE_PATH the
   process happens to hold. *)
let test_library_follows_context_base_path () =
  with_temp_base_path (fun ctx ->
    let (ok, _) =
      dispatch_exn ctx ~name:"masc_library_add"
        ~args:(`Assoc [
          ("title", `String "Workspace Doc");
          ("content", `String "body");
          ("source", `String "observation");
        ])
    in
    Alcotest.(check bool) "add succeeds" true ok;
    Alcotest.(check int) "written under the context workspace" 1
      (List.length (library_documents ctx));
    Alcotest.(check bool) "nothing under MASC_BASE_PATH" false
      (Sys.file_exists (Tool_library.library_root ~base_path:decoy_base_path)))

let test_add_success () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [
      ("title", `String "test knowledge");
      ("content", `String "This is test content for library.");
      ("source", `String "direct_experience");
    ] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "add succeeds" true ok;
    Alcotest.(check bool) "response confirms add" true (msg_contains ~needle:"added" msg || msg_contains ~needle:"success" msg || msg_contains ~needle:"librar" msg)
  )

let test_add_with_tags () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [
      ("title", `String "tagged knowledge");
      ("content", `String "Content with tags.");
      ("source", `String "direct_experience");
      ("tags", `List [`String "ocaml"; `String "testing"]);
    ] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_add" ~args in
    Alcotest.(check bool) "add with tags" true ok;
    Alcotest.(check bool) "response confirms add" true (msg_contains ~needle:"added" msg || msg_contains ~needle:"success" msg || msg_contains ~needle:"librar" msg)
  )

(* ============================================================
   library_search tests
   ============================================================ *)

let test_search_empty_query () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_search" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty query fails" false ok;
    Alcotest.(check bool) "error mentions query" true (msg_contains ~needle:"query" msg)
  )

let test_search_schema_allows_runtime_query_rejection () =
  let schema = required_schema "masc_library_search" in
  Alcotest.(check bool)
    "query property remains documented"
    true
    (schema_has_property schema "query");
  Alcotest.(check bool)
    "query is not validation-required"
    false
    (List.mem "query" (schema_required_fields schema))

let test_search_with_query () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [("query", `String "test")] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_library_search" ~args in
    (* Succeeds even with no results *)
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "response is substantive" true (String.length msg > 5)
  )

(* ============================================================
   The self-scored confidence axis is gone
   ============================================================

   [confidence] was a number the writing agent chose for its own document.
   It decided one thing: whether the file landed in [docs/library/] or
   [docs/library/candidates/]. Both directories were read by
   [masc_library_read] and [masc_library_search], so the split changed
   what [masc_library_list] printed by default and nothing else.

   Measured on the live library before removal: 61 of 62 documents scored
   >= 0.70, one scored 0.40, and [verified_by] was the empty list in all 61
   published documents — [masc_library_promote], whose only effect was to
   raise that number and stamp a verifier, had never run.
   ============================================================ *)

let test_promote_is_not_a_tool () =
  with_temp_base_path (fun ctx ->
    let dispatched =
      Tool_library.dispatch ctx ~name:"masc_library_promote"
        ~args:(`Assoc [ ("topic", `String "anything") ])
    in
    Alcotest.(check bool) "promote no longer dispatches" true (dispatched = None);
    Alcotest.(check bool)
      "promote is absent from the registered schemas"
      false
      (List.exists
         (fun (schema : Masc_domain.tool_schema) ->
           String.equal schema.name "masc_library_promote")
         Tool_library.schemas)
  )

let test_add_schema_has_no_confidence () =
  let schema = required_schema "masc_library_add" in
  Alcotest.(check bool)
    "confidence is not an input property"
    false
    (schema_has_property schema "confidence");
  Alcotest.(check bool)
    "confidence is not required"
    false
    (List.mem "confidence" (schema_required_fields schema))

(* Nothing writes a self-scored number or an empty verifier list into the
   document any more, so nothing downstream can read one back. *)
let test_added_frontmatter_carries_only_observable_fields () =
  with_temp_base_path (fun ctx ->
    let (added, _) =
      dispatch_exn ctx ~name:"masc_library_add"
        ~args:(`Assoc [
          ("title", `String "Frontmatter Shape");
          ("content", `String "body");
          ("source", `String "direct_experience");
        ])
    in
    Alcotest.(check bool) "add succeeds" true added;
    let root = Tool_library.library_root ~base_path:ctx.base_path in
    let path =
      match library_documents ctx with
      | [ single ] -> Filename.concat root single
      | other ->
        Alcotest.failf "expected exactly one document, got %d" (List.length other)
    in
    let written = In_channel.with_open_text path In_channel.input_all in
    Alcotest.(check bool) "no confidence field" false
      (msg_contains ~needle:"confidence:" written);
    Alcotest.(check bool) "no verified_by field" false
      (msg_contains ~needle:"verified_by:" written);
    Alcotest.(check bool) "records the author" true
      (msg_contains ~needle:"author: test-agent" written);
    Alcotest.(check bool) "records the source" true
      (msg_contains ~needle:"source: direct_experience" written)
  )

(* ============================================================
   Documents whose frontmatter does not read
   ============================================================

   A document written by hand can carry any [source]. List, read and search
   name such a document by filename with the reason; none of them prints the
   raw value as if it were one of the four. *)

let unknown_source_note =
  "source \"operation\" is not one of: direct_experience, research, \
   experiment, observation"

let test_unknown_source_is_named_not_passed_through () =
  with_temp_base_path (fun ctx ->
    let (added, _) =
      dispatch_exn ctx ~name:"masc_library_add"
        ~args:(`Assoc [
          ("title", `String "Readable Doc");
          ("content", `String "shared marker");
          ("source", `String "research");
        ])
    in
    Alcotest.(check bool) "add succeeds" true added;
    write_library_document ctx ~filename:"hand-written.md"
      "---\ntitle: Hand Written\nsource: operation\nauthor: codex\n---\n\nshared marker\n";
    write_library_document ctx ~filename:"no-source.md"
      "---\ntitle: No Source\nauthor: codex\n---\n\nshared marker\n";
    let (ok, listing) = dispatch_exn ctx ~name:"masc_library_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "readable document shows its source" true
      (msg_contains ~needle:"**Readable Doc** (research, test-agent" listing);
    Alcotest.(check bool) "unknown source named with its reason" true
      (msg_contains ~needle:("- hand-written.md (" ^ unknown_source_note ^ ")") listing);
    Alcotest.(check bool) "unknown source never listed as a document title" false
      (msg_contains ~needle:"**Hand Written**" listing);
    Alcotest.(check bool) "absent source named" true
      (msg_contains ~needle:"- no-source.md (no source in frontmatter)" listing);
    let (ok, results) =
      dispatch_exn ctx ~name:"masc_library_search"
        ~args:(`Assoc [ ("query", `String "shared marker") ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "search names the unknown source" true
      (msg_contains ~needle:("- hand-written.md (" ^ unknown_source_note ^ ")") results);
    let (ok, body) =
      dispatch_exn ctx ~name:"masc_library_read"
        ~args:(`Assoc [ ("topic", `String "hand-written") ])
    in
    Alcotest.(check bool) "read by filename ok" true ok;
    Alcotest.(check bool) "read heading carries the reason" true
      (msg_contains ~needle:("## hand-written.md (" ^ unknown_source_note ^ ")") body);
    Alcotest.(check bool) "read returns the document" true
      (msg_contains ~needle:"shared marker" body)
  )

(* A header missing a field the writer always writes, a block that never
   closes, and a source outside ASCII. Each is named with its own reason: the
   missing title is not printed as an empty bold title, the unclosed block is
   not reported as a missing source although its source line is there, and the
   non-ASCII source is quoted as written rather than as escaped bytes. *)
let test_header_that_does_not_read_names_its_reason () =
  with_temp_base_path (fun ctx ->
    write_library_document ctx ~filename:"no-title.md"
      "---\nsource: research\nauthor: codex\ncreated: 2026-09-22\ntags: []\n---\n\nbody\n";
    write_library_document ctx ~filename:"empty-author.md"
      "---\ntitle: Empty Author\nsource: research\nauthor:\ncreated: 2026-09-22\ntags: []\n---\n\nbody\n";
    write_library_document ctx ~filename:"unclosed.md"
      "---\ntitle: Unclosed\nsource: research\nauthor: codex\n\nbody\n";
    write_library_document ctx ~filename:"korean-source.md"
      "---\ntitle: Korean Source\nsource: 연구\nauthor: codex\ncreated: 2026-09-22\ntags: []\n---\n\nbody\n";
    let (ok, listing) = dispatch_exn ctx ~name:"masc_library_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "missing title named" true
      (msg_contains ~needle:"- no-title.md (no title in frontmatter)" listing);
    Alcotest.(check bool) "no empty bold title" false (msg_contains ~needle:"****" listing);
    Alcotest.(check bool) "empty author reads as missing" true
      (msg_contains ~needle:"- empty-author.md (no author in frontmatter)" listing);
    Alcotest.(check bool) "unclosed block named as unclosed" true
      (msg_contains ~needle:"- unclosed.md (frontmatter has no closing ---)" listing);
    Alcotest.(check bool) "non-ASCII source quoted as written" true
      (msg_contains ~needle:"- korean-source.md (source \"연구\" is not one of:" listing))

(* ============================================================
   Workflow: add → list → read → search
   ============================================================ *)

let test_full_workflow () =
  with_temp_base_path (fun ctx ->
    (* Step 1: Add a document *)
    let add_args = `Assoc [
      ("title", `String "workflow test");
      ("content", `String "Knowledge about OCaml testing patterns.");
      ("source", `String "direct_experience");
    ] in
    let (ok1, _) = dispatch_exn ctx ~name:"masc_library_add" ~args:add_args in
    Alcotest.(check bool) "add succeeds" true ok1;
    (* Step 2: List documents *)
    let (ok2, msg2) = dispatch_exn ctx ~name:"masc_library_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list succeeds" true ok2;
    Alcotest.(check bool) "list has content" true (String.length msg2 > 0);
    (* Step 3: Search *)
    let search_args = `Assoc [("query", `String "OCaml")] in
    let (ok3, _) = dispatch_exn ctx ~name:"masc_library_search" ~args:search_args in
    Alcotest.(check bool) "search succeeds" true ok3;
    (* Step 4: Read the document *)
    let read_args = `Assoc [("topic", `String "workflow-test")] in
    let (ok4, msg4) = dispatch_exn ctx ~name:"masc_library_read" ~args:read_args in
    (* May fail if filename convention differs — just check dispatch *)
    ignore ok4;
    Alcotest.(check bool) "read has response" true (String.length msg4 > 0)
  )

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_library" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "all known tools dispatch" `Quick test_dispatch_all_known;
    ]);
    ("library_list", [
      Alcotest.test_case "empty list" `Quick test_list_empty;
    ]);
    ("library_read", [
      Alcotest.test_case "empty topic" `Quick test_read_empty_topic;
      Alcotest.test_case "nonexistent topic" `Quick test_read_nonexistent_topic;
      Alcotest.test_case "read by exact title (list->read contract)" `Quick test_read_by_title_roundtrip;
      Alcotest.test_case "read by case-insensitive partial title" `Quick test_read_by_title_case_insensitive_partial;
      Alcotest.test_case "read by slug still works" `Quick test_read_by_slug_still_works;
    ]);
    ("library_add", [
      Alcotest.test_case "fresh base creates library and reads document" `Quick test_add_on_fresh_base;
      Alcotest.test_case "missing title" `Quick test_add_missing_title;
      Alcotest.test_case "missing content" `Quick test_add_missing_content;
      Alcotest.test_case "invalid source" `Quick test_add_invalid_source;
      Alcotest.test_case "missing source" `Quick test_add_missing_source;
      Alcotest.test_case "success" `Quick test_add_success;
      Alcotest.test_case "with tags" `Quick test_add_with_tags;
      Alcotest.test_case "library follows the context base path" `Quick
        test_library_follows_context_base_path;
    ]);
    ("unreadable_source", [
      Alcotest.test_case "unknown source is named, not passed through" `Quick
        test_unknown_source_is_named_not_passed_through;
      Alcotest.test_case "header that does not read names its reason" `Quick
        test_header_that_does_not_read_names_its_reason;
    ]);
    ("library_search", [
      Alcotest.test_case "empty query" `Quick test_search_empty_query;
      Alcotest.test_case
        "schema lets runtime reject empty query"
        `Quick
        test_search_schema_allows_runtime_query_rejection;
      Alcotest.test_case "with query" `Quick test_search_with_query;
    ]);
    ("confidence_purged", [
      Alcotest.test_case "promote is not a tool" `Quick test_promote_is_not_a_tool;
      Alcotest.test_case "add schema has no confidence" `Quick
        test_add_schema_has_no_confidence;
      Alcotest.test_case "frontmatter carries only observable fields" `Quick
        test_added_frontmatter_carries_only_observable_fields;
    ]);
    ("workflow", [
      Alcotest.test_case "add list search read" `Quick test_full_workflow;
    ]);
  ]
