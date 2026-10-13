(** Coverage tests for Tool_wiki — Wiki page management

    Tests dispatch routing, input validation, and handler integration
    for 5 tools: masc_wiki_list, masc_wiki_read, masc_wiki_create,
    masc_wiki_update, masc_wiki_search

    The wiki lives under the context's [base_path]; each test hands the
    tools a temp directory as that workspace.
*)

module Tool_wiki = Masc.Tool_wiki

let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try ignore (Str.search_forward (Str.regexp_string ln) lc 0); true
  with Not_found -> false

let required_schema name =
  match
    List.find_opt
      (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
      Tool_wiki.schemas
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
    (Printf.sprintf "test_wiki_%d_" !test_counter) "" in
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

(* The wiki takes its workspace from the context, never from the process
   environment. The suite still points MASC_BASE_PATH at a scratch directory of
   its own: a regression that reads the variable again then writes there, where
   [test_wiki_follows_context_base_path] looks, and not into the live
   workspace a developer's shell exports. *)
let decoy_base_path =
  let dir = temp_dir () in
  Unix.putenv "MASC_BASE_PATH" dir;
  at_exit (fun () -> cleanup_dir dir);
  dir

(** Create the expected wiki directory structure under a temp base path. *)
let setup_wiki_dirs base_path =
  let docs_dir = Filename.concat base_path "docs" in
  let lib_dir = Filename.concat docs_dir "wiki" in
  Unix.mkdir docs_dir 0o755;
  Unix.mkdir lib_dir 0o755;
  lib_dir

(** Run a test function with a temporary workspace containing wiki dirs. *)
let with_temp_base_path ?(prepare_wiki=true) f =
  let base_path = temp_dir () in
  if prepare_wiki then ignore (setup_wiki_dirs base_path);
  let ctx : Tool_wiki.context = { base_path; agent_name = "test-agent" } in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () -> f ctx)

(* Every Markdown file in the wiki directory, the wiki's own two included. *)
let wiki_markdown_files (ctx : Tool_wiki.context) =
  let root = Tool_wiki.wiki_root ~base_path:ctx.base_path in
  if Sys.file_exists root
  then
    Sys.readdir root |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".md")
  else []

(* The page files: what a writer put there, without index.md and log.md. *)
let wiki_pages ctx =
  wiki_markdown_files ctx
  |> List.filter (fun f -> not (List.mem f [ "index.md"; "log.md" ]))

let write_wiki_page (ctx : Tool_wiki.context) ~filename body =
  let path =
    Filename.concat (Tool_wiki.wiki_root ~base_path:ctx.base_path) filename
  in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc body)

let dispatch_exn ctx ~name ~args =
  match Tool_wiki.dispatch ctx ~name ~args with
  | Some result -> ((Tool_result.is_success result), (Tool_result.message result))
  | None -> failwith ("dispatch returned None for " ^ name)

let dispatch_result ctx ~name ~args =
  match Tool_wiki.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let create_args
      ?(page = "test-page")
      ?(title = "Test Page")
      ?(summary = "One line about the page")
      ?(source = "research")
      ?(body = "page body")
      ?tags
      ()
  =
  `Assoc
    ([ "page", `String page
     ; "title", `String title
     ; "summary", `String summary
     ; "source", `String source
     ; "body", `String body
     ]
     @
     match tags with
     | None -> []
     | Some tags -> [ "tags", `List (List.map (fun tag -> `String tag) tags) ])

let without field = function
  | `Assoc fields -> `Assoc (List.remove_assoc field fields)
  | other -> other

let create ctx args = dispatch_exn ctx ~name:"masc_wiki_create" ~args

let create_ok ctx args =
  let ok, msg = create ctx args in
  if not ok then Alcotest.failf "create should succeed: %s" msg

let read_file (ctx : Tool_wiki.context) page =
  In_channel.with_open_text
    (Tool_wiki.page_path ~base_path:ctx.base_path page)
    In_channel.input_all

let frontmatter_of ctx page =
  match Tool_wiki.parse_frontmatter (read_file ctx page) with
  | Ok frontmatter -> frontmatter
  | Error error ->
    Alcotest.failf "%s does not read: %s" page (Tool_wiki.frontmatter_error_to_string error)

let update_args ?title ?summary ?tags ?(note = "why it changed") ~page ~base_revision ~body () =
  let optional name = function
    | None -> []
    | Some value -> [ name, `String value ]
  in
  `Assoc
    ([ "page", `String page
     ; "base_revision", `Int base_revision
     ; "body", `String body
     ; "note", `String note
     ]
     @ optional "title" title
     @ optional "summary" summary
     @
     match tags with
     | None -> []
     | Some tags -> [ "tags", `List (List.map (fun tag -> `String tag) tags) ])

let update ctx args = dispatch_exn ctx ~name:"masc_wiki_update" ~args

let test_create_on_fresh_base () =
  List.iter (fun title ->
    with_temp_base_path ~prepare_wiki:false (fun ctx ->
      Alcotest.(check bool) "wiki initially absent" false
        (Sys.file_exists (Tool_wiki.wiki_root ~base_path:ctx.base_path));
      create_ok ctx (create_args ~page:"fresh" ~title ~body:"fresh base evidence" ());
      let ok, content = dispatch_exn ctx ~name:"masc_wiki_read"
          ~args:(`Assoc ["topic", `String title]) in
      Alcotest.(check bool) "saved page readable" true ok;
      Alcotest.(check bool) "exact content retained" true
        (String_util.contains_substring content "fresh base evidence")))
    ["Fresh wiki"; "새 위키"]

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  with_temp_base_path (fun ctx ->
    let result = Tool_wiki.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
    Alcotest.(check bool) "unknown returns None" true (result = None)
  )

let test_dispatch_all_known () =
  with_temp_base_path (fun ctx ->
    let tools = [
      "masc_wiki_list"; "masc_wiki_read"; "masc_wiki_create";
      "masc_wiki_update"; "masc_wiki_search";
    ] in
    List.iter (fun name ->
      let result = Tool_wiki.dispatch ctx ~name ~args:(`Assoc []) in
      Alcotest.(check bool) (name ^ " dispatches") true (result <> None)
    ) tools
  )

(* ============================================================
   wiki_list tests
   ============================================================ *)

let test_list_empty () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "response mentions the wiki" true (msg_contains ~needle:"wiki" msg)
  )

(* ============================================================
   wiki_read tests
   ============================================================ *)

let test_read_empty_topic () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = dispatch_exn ctx ~name:"masc_wiki_read" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty topic fails" false ok;
    Alcotest.(check bool) "error mentions topic" true (msg_contains ~needle:"topic" msg)
  )

let test_read_nonexistent_topic () =
  with_temp_base_path (fun ctx ->
    let args = `Assoc [("topic", `String "nonexistent_topic")] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_wiki_read" ~args in
    Alcotest.(check bool) "nonexistent fails" false ok;
    Alcotest.(check bool) "error names the topic" true
      (msg_contains ~needle:"No page matching 'nonexistent_topic'" msg)
  )

(* The list -> read contract: masc_wiki_list surfaces the frontmatter title,
   so reading back that exact title must resolve the page. The page name
   carries none of the title's spaces, colons or case. *)
let test_read_by_title_roundtrip () =
  with_temp_base_path (fun ctx ->
    let title = "Blocker Chain V3: Repos Exists, The Real Blocker" in
    create_ok ctx
      (create_args ~page:"blocker-chain" ~title ~body:"Body of the page for round-trip." ());
    let read_args = `Assoc [("topic", `String title)] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_wiki_read" ~args:read_args in
    Alcotest.(check bool) "read by exact title succeeds" true ok;
    Alcotest.(check bool) "returns the body" true
      (msg_contains ~needle:"Body of the page" msg);
    Alcotest.(check bool) "returns the revision the next update needs" true
      (msg_contains ~needle:"revision: 1" msg)
  )

let test_read_by_title_case_insensitive_partial () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"orphan-count" ~title:"Root Cause: Orphan Count Analysis" ());
    let read_args = `Assoc [("topic", `String "root cause: orphan count")] in
    let (ok, _) = dispatch_exn ctx ~name:"masc_wiki_read" ~args:read_args in
    Alcotest.(check bool) "case-insensitive partial title match" true ok
  )

(* A page is also found by part of its name. *)
let test_read_by_page_name () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"slug-query-doc" ~title:"Unrelated Title" ());
    let read_args = `Assoc [("topic", `String "slug-query")] in
    let (ok, _) = dispatch_exn ctx ~name:"masc_wiki_read" ~args:read_args in
    Alcotest.(check bool) "page name substring matches" true ok
  )

(* ============================================================
   wiki_create tests
   ============================================================ *)

let test_create_missing_field field () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = create ctx (without field (create_args ())) in
    Alcotest.(check bool) ("missing " ^ field ^ " fails") false ok;
    Alcotest.(check bool) "names the missing field" true
      (msg_contains ~needle:(field ^ " is required") msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx))

let test_create_invalid_source () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = create ctx (create_args ~source:"invalid_source_type" ()) in
    Alcotest.(check bool) "invalid source fails" false ok;
    Alcotest.(check bool) "mentions source" true (msg_contains ~needle:"source" msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx))

(* The reader requires [author], so the writer refuses a caller with no name
   instead of writing a page the wiki then reports as unreadable. *)
let test_create_with_blank_author_is_refused () =
  with_temp_base_path (fun ctx ->
    let ctx = { ctx with Tool_wiki.agent_name = "  " } in
    let (ok, msg) = create ctx (create_args ()) in
    Alcotest.(check bool) "blank author fails" false ok;
    Alcotest.(check bool) "names the author" true
      (msg_contains ~needle:"no agent name" msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx)
  )

(* The wiki is the caller's workspace, not whatever MASC_BASE_PATH the
   process happens to hold. *)
let test_wiki_follows_context_base_path () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"workspace-doc" ());
    Alcotest.(check (list string)) "written under the context workspace"
      [ "workspace-doc.md" ] (wiki_pages ctx);
    Alcotest.(check bool) "nothing under MASC_BASE_PATH" false
      (Sys.file_exists (Tool_wiki.wiki_root ~base_path:decoy_base_path)))

(* The file is named by [page] alone: no date, nothing taken from the title. *)
let test_create_names_the_file_by_page () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"saju-palja" ~title:"사주팔자" ~tags:[ "band"; "song" ] ());
    Alcotest.(check (list string)) "one file, named by page" [ "saju-palja.md" ]
      (wiki_pages ctx);
    let frontmatter = frontmatter_of ctx "saju-palja" in
    Alcotest.(check string) "title kept as written" "사주팔자" frontmatter.title;
    Alcotest.(check string) "summary kept" "One line about the page" frontmatter.summary;
    Alcotest.(check int) "starts at revision 1" 1 frontmatter.revision;
    Alcotest.(check string) "author is the caller" "test-agent" frontmatter.author;
    Alcotest.(check (list string)) "tags kept" [ "band"; "song" ] frontmatter.tags)

(* Two titles in a script the name cannot carry used to collapse into one
   file and the second silently replaced the first. *)
let test_two_korean_titles_do_not_collide () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"saju-palja" ~title:"사주팔자" ~body:"first" ());
    create_ok ctx (create_args ~page:"bamseom" ~title:"밤섬" ~body:"second" ());
    Alcotest.(check (list string)) "both pages exist"
      [ "bamseom.md"; "saju-palja.md" ]
      (List.sort String.compare (wiki_pages ctx));
    Alcotest.(check bool) "the first page still holds its own body" true
      (String_util.contains_substring (read_file ctx "saju-palja") "first"))

let test_create_refuses_an_existing_page () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"taken" ~body:"original body" ());
    let before = read_file ctx "taken" in
    let (ok, msg) = create ctx (create_args ~page:"taken" ~body:"replacement body" ()) in
    Alcotest.(check bool) "second create fails" false ok;
    Alcotest.(check bool) "points at update" true
      (msg_contains ~needle:"masc_wiki_update" msg);
    Alcotest.(check string) "the page is untouched" before (read_file ctx "taken"))

let test_create_refuses_a_bad_page_name () =
  List.iter
    (fun page ->
       with_temp_base_path (fun ctx ->
         let (ok, _) = create ctx (create_args ~page ()) in
         Alcotest.(check bool) (Printf.sprintf "page %S is refused" page) false ok;
         Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx)))
    [ ""; "Upper"; "사주팔자"; "has space"; "-leading"; "trailing-"; "dot.name"
    ; "under_score"; "index"; "log"; "../escape" ]

let test_create_refuses_a_multi_line_title_or_summary () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = create ctx (create_args ~title:"two\nlines" ()) in
    Alcotest.(check bool) "multi-line title fails" false ok;
    Alcotest.(check bool) "names the title" true (msg_contains ~needle:"title must be one line" msg);
    let (ok, msg) = create ctx (create_args ~summary:"two\nlines" ()) in
    Alcotest.(check bool) "multi-line summary fails" false ok;
    Alcotest.(check bool) "names the summary" true
      (msg_contains ~needle:"summary must be one line" msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx))

(* ============================================================
   wiki_update tests
   ============================================================ *)

let test_update_replaces_the_body_and_adds_one_to_the_revision () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"notes" ~title:"Notes" ~source:"experiment" ~tags:[ "a" ]
         ~body:"first body" ());
    let created = frontmatter_of ctx "notes" in
    let (ok, msg) = update ctx (update_args ~page:"notes" ~base_revision:1 ~body:"second body" ()) in
    Alcotest.(check bool) ("update succeeds: " ^ msg) true ok;
    let updated = frontmatter_of ctx "notes" in
    let content = read_file ctx "notes" in
    Alcotest.(check int) "revision is 2" 2 updated.revision;
    Alcotest.(check bool) "new body is there" true
      (String_util.contains_substring content "second body");
    Alcotest.(check bool) "old body is gone" false
      (String_util.contains_substring content "first body");
    Alcotest.(check string) "title kept" created.title updated.title;
    Alcotest.(check string) "summary kept" created.summary updated.summary;
    Alcotest.(check string) "author kept" created.author updated.author;
    Alcotest.(check string) "created kept" created.created updated.created;
    Alcotest.(check bool) "source kept" true (created.source = updated.source);
    Alcotest.(check (list string)) "tags kept" created.tags updated.tags)

let test_update_can_change_title_summary_and_tags () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"notes" ~tags:[ "a" ] ());
    let (ok, msg) =
      update ctx
        (update_args ~page:"notes" ~base_revision:1 ~body:"b" ~title:"새 제목"
           ~summary:"new summary" ~tags:[ "x"; "y" ] ())
    in
    Alcotest.(check bool) ("update succeeds: " ^ msg) true ok;
    let updated = frontmatter_of ctx "notes" in
    Alcotest.(check string) "title changed" "새 제목" updated.title;
    Alcotest.(check string) "summary changed" "new summary" updated.summary;
    Alcotest.(check (list string)) "tags changed" [ "x"; "y" ] updated.tags)

(* The writer read revision 1, someone else moved the page to 2. The update is
   refused, the page keeps the other writer's body, and the refusal carries
   what the writer needs to merge and send again. *)
let test_stale_update_is_refused_with_the_current_page () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"shared" ~body:"first body" ());
    let (ok, _) = update ctx (update_args ~page:"shared" ~base_revision:1 ~body:"other writer's body" ()) in
    Alcotest.(check bool) "first update succeeds" true ok;
    let before = read_file ctx "shared" in
    let result =
      dispatch_result ctx ~name:"masc_wiki_update"
        ~args:(update_args ~page:"shared" ~base_revision:1 ~body:"my stale body" ())
    in
    Alcotest.(check bool) "stale update fails" false (Tool_result.is_success result);
    Alcotest.(check string) "the page is untouched" before (read_file ctx "shared");
    let data = Tool_result.data result in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "refusal carries the current revision" 2
      (data |> member "current_revision" |> to_int);
    Alcotest.(check string) "refusal carries the current body" "other writer's body\n"
      (data |> member "body" |> to_string);
    Alcotest.(check bool) "the message carries the body too" true
      (String_util.contains_substring (Tool_result.message result) "other writer's body");
    (* The writer merges and sends again with the revision it was handed. *)
    let (ok, msg) =
      update ctx
        (update_args ~page:"shared" ~base_revision:2
           ~body:"other writer's body\nplus my change" ())
    in
    Alcotest.(check bool) ("resend succeeds: " ^ msg) true ok;
    Alcotest.(check int) "revision is 3" 3 (frontmatter_of ctx "shared").revision)

let test_update_refuses_a_page_that_does_not_exist () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = update ctx (update_args ~page:"absent" ~base_revision:1 ~body:"b" ()) in
    Alcotest.(check bool) "update of an absent page fails" false ok;
    Alcotest.(check bool) "points at create" true (msg_contains ~needle:"masc_wiki_create" msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx))

(* [source] says what kind of work the page first came from. *)
let test_update_cannot_change_the_source () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"notes" ~source:"research" ());
    let before = read_file ctx "notes" in
    let args =
      match update_args ~page:"notes" ~base_revision:1 ~body:"b" () with
      | `Assoc fields -> `Assoc (("source", `String "experiment") :: fields)
    in
    let (ok, msg) = update ctx args in
    Alcotest.(check bool) "update with a source fails" false ok;
    Alcotest.(check bool) "names the source" true (msg_contains ~needle:"source cannot change" msg);
    Alcotest.(check string) "the page is untouched" before (read_file ctx "notes"))

let test_update_missing_field field () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"notes" ());
    let before = read_file ctx "notes" in
    let (ok, msg) =
      update ctx (without field (update_args ~page:"notes" ~base_revision:1 ~body:"b" ()))
    in
    Alcotest.(check bool) ("missing " ^ field ^ " fails") false ok;
    Alcotest.(check bool) "names the missing field" true
      (msg_contains ~needle:(field ^ " is required") msg);
    Alcotest.(check string) "the page is untouched" before (read_file ctx "notes"))

(* A page whose header does not read has no revision to compare, so it is
   not rewritten. *)
let test_update_refuses_a_page_whose_header_does_not_read () =
  with_temp_base_path (fun ctx ->
    let hand_written = "---\ntitle: Hand Written\n---\n\nbody\n" in
    write_wiki_page ctx ~filename:"hand.md" hand_written;
    let (ok, msg) = update ctx (update_args ~page:"hand" ~base_revision:1 ~body:"b" ()) in
    Alcotest.(check bool) "update fails" false ok;
    Alcotest.(check bool) "says why" true (msg_contains ~needle:"does not read" msg);
    Alcotest.(check string) "the page is untouched" hand_written (read_file ctx "hand"))

(* ============================================================
   wiki_search tests
   ============================================================ *)

let test_search_empty_query () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc []) in
    Alcotest.(check bool) "empty query fails" false ok;
    Alcotest.(check bool) "error mentions query" true (msg_contains ~needle:"query" msg)
  )

let test_search_schema_allows_runtime_query_rejection () =
  let schema = required_schema "masc_wiki_search" in
  Alcotest.(check bool)
    "query property remains documented"
    true
    (schema_has_property schema "query");
  Alcotest.(check bool)
    "query is not validation-required"
    false
    (List.mem "query" (schema_required_fields schema))

let test_search_finds_a_page_by_its_body () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"found" ~title:"Found Page" ~body:"needle in the body" ());
    create_ok ctx (create_args ~page:"other" ~title:"Other Page" ~body:"nothing here" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc [ "query", `String "needle" ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "names the matching page" true
      (msg_contains ~needle:"**Found Page** found.md" msg);
    Alcotest.(check bool) "leaves the other page out" false
      (msg_contains ~needle:"Other Page" msg))

let test_create_schema_requires_what_the_handler_requires () =
  let schema = required_schema "masc_wiki_create" in
  Alcotest.(check (list string))
    "required fields"
    [ "body"; "page"; "source"; "summary"; "title" ]
    (List.sort String.compare (schema_required_fields schema));
  let schema = required_schema "masc_wiki_update" in
  Alcotest.(check (list string))
    "update required fields"
    [ "base_revision"; "body"; "note"; "page" ]
    (List.sort String.compare (schema_required_fields schema));
  Alcotest.(check bool) "update offers no source" false (schema_has_property schema "source")

(* ============================================================
   Pages whose frontmatter does not read
   ============================================================

   A page written by hand can carry any [source]. List, read and search
   name such a page by filename with the reason; none of them prints the
   raw value as if it were one of the four. *)

let unknown_source_note =
  "source \"operation\" is not one of: direct_experience, research, \
   experiment, observation"

let test_unknown_source_is_named_not_passed_through () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"readable" ~title:"Readable Doc" ~body:"shared marker" ());
    write_wiki_page ctx ~filename:"hand-written.md"
      "---\ntitle: Hand Written\nsummary: s\nsource: operation\nauthor: codex\n---\n\nshared marker\n";
    write_wiki_page ctx ~filename:"no-source.md"
      "---\ntitle: No Source\nsummary: s\nauthor: codex\n---\n\nshared marker\n";
    let (ok, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "readable page shows its title, file and summary" true
      (msg_contains ~needle:"- [Readable Doc](readable.md) — One line about the page" listing);
    Alcotest.(check bool) "unknown source named with its reason" true
      (msg_contains ~needle:("- hand-written.md (" ^ unknown_source_note ^ ")") listing);
    Alcotest.(check bool) "unknown source never listed as a page title" false
      (msg_contains ~needle:"[Hand Written]" listing);
    Alcotest.(check bool) "absent source named" true
      (msg_contains ~needle:"- no-source.md (no source in frontmatter)" listing);
    let (ok, results) =
      dispatch_exn ctx ~name:"masc_wiki_search"
        ~args:(`Assoc [ ("query", `String "shared marker") ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "search names the unknown source" true
      (msg_contains ~needle:("- hand-written.md (" ^ unknown_source_note ^ ")") results);
    let (ok, body) =
      dispatch_exn ctx ~name:"masc_wiki_read"
        ~args:(`Assoc [ ("topic", `String "hand-written") ])
    in
    Alcotest.(check bool) "read by filename ok" true ok;
    Alcotest.(check bool) "read heading carries the reason" true
      (msg_contains ~needle:("## hand-written.md (" ^ unknown_source_note ^ ")") body);
    Alcotest.(check bool) "read returns the page" true
      (msg_contains ~needle:"shared marker" body)
  )

(* A header missing a field the writer always writes, a block that never
   closes, a source outside ASCII, and a revision that is not a number. Each is
   named with its own reason: the missing title is not printed as an empty bold
   title, the unclosed block is not reported as a missing source although its
   source line is there, and the non-ASCII source is quoted as written rather
   than as escaped bytes. *)
let test_header_that_does_not_read_names_its_reason () =
  with_temp_base_path (fun ctx ->
    let header fields = "---\n" ^ String.concat "\n" fields ^ "\n---\n\nbody\n" in
    write_wiki_page ctx ~filename:"no-title.md"
      (header [ "summary: s"; "source: research"; "author: codex"; "created: 2026-09-22"
              ; "revision: 1"; "tags: []" ]);
    write_wiki_page ctx ~filename:"empty-author.md"
      (header [ "title: Empty Author"; "summary: s"; "source: research"; "author:"
              ; "created: 2026-09-22"; "revision: 1"; "tags: []" ]);
    write_wiki_page ctx ~filename:"unclosed.md"
      "---\ntitle: Unclosed\nsummary: s\nsource: research\nauthor: codex\n\nbody\n";
    write_wiki_page ctx ~filename:"korean-source.md"
      (header [ "title: Korean Source"; "summary: s"; "source: 연구"; "author: codex"
              ; "created: 2026-09-22"; "revision: 1"; "tags: []" ]);
    write_wiki_page ctx ~filename:"no-summary.md"
      (header [ "title: No Summary"; "source: research"; "author: codex"
              ; "created: 2026-09-22"; "revision: 1"; "tags: []" ]);
    write_wiki_page ctx ~filename:"no-revision.md"
      (header [ "title: No Revision"; "summary: s"; "source: research"; "author: codex"
              ; "created: 2026-09-22"; "tags: []" ]);
    write_wiki_page ctx ~filename:"bad-revision.md"
      (header [ "title: Bad Revision"; "summary: s"; "source: research"; "author: codex"
              ; "created: 2026-09-22"; "revision: two"; "tags: []" ]);
    write_wiki_page ctx ~filename:"zero-revision.md"
      (header [ "title: Zero Revision"; "summary: s"; "source: research"; "author: codex"
              ; "created: 2026-09-22"; "revision: 0"; "tags: []" ]);
    let (ok, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "missing title named" true
      (msg_contains ~needle:"- no-title.md (no title in frontmatter)" listing);
    Alcotest.(check bool) "no empty title link" false (msg_contains ~needle:"[](" listing);
    Alcotest.(check bool) "empty author reads as missing" true
      (msg_contains ~needle:"- empty-author.md (no author in frontmatter)" listing);
    Alcotest.(check bool) "unclosed block named as unclosed" true
      (msg_contains ~needle:"- unclosed.md (frontmatter has no closing ---)" listing);
    Alcotest.(check bool) "non-ASCII source quoted as written" true
      (msg_contains ~needle:"- korean-source.md (source \"연구\" is not one of:" listing);
    Alcotest.(check bool) "missing summary named" true
      (msg_contains ~needle:"- no-summary.md (no summary in frontmatter)" listing);
    Alcotest.(check bool) "missing revision named" true
      (msg_contains ~needle:"- no-revision.md (no revision in frontmatter)" listing);
    Alcotest.(check bool) "non-numeric revision named" true
      (msg_contains ~needle:"- bad-revision.md (revision \"two\" is not a whole number from 1)" listing);
    Alcotest.(check bool) "revision 0 named" true
      (msg_contains ~needle:"- zero-revision.md (revision \"0\" is not a whole number from 1)" listing))

(* ============================================================
   Header values that would not read back
   ============================================================

   A header value is one line, [key: value], read back trimmed. The tags line
   is [tags: \[a, b\]]. A value that would come back as something else is
   refused when it is written, not cut down when it is read. *)

let unstorable_tags =
  [ "x\n---\nINJECTED"; "two\nlines"; "a,b"; "a]"; "[a"; " lead"; "trail " ]

let test_create_refuses_a_tag_that_would_not_read_back () =
  List.iter
    (fun tag ->
       with_temp_base_path (fun ctx ->
         let (ok, msg) = create ctx (create_args ~tags:[ "ok"; tag ] ()) in
         Alcotest.(check bool) (Printf.sprintf "tag %S is refused" tag) false ok;
         Alcotest.(check bool) "says the tag cannot be stored" true
           (msg_contains ~needle:"cannot be stored" msg);
         Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx)))
    unstorable_tags

let test_update_refuses_a_tag_that_would_not_read_back () =
  List.iter
    (fun tag ->
       with_temp_base_path (fun ctx ->
         create_ok ctx (create_args ~page:"notes" ~tags:[ "kept" ] ());
         let before = read_file ctx "notes" in
         let (ok, _) =
           update ctx (update_args ~page:"notes" ~base_revision:1 ~body:"b" ~tags:[ tag ] ())
         in
         Alcotest.(check bool) (Printf.sprintf "tag %S is refused" tag) false ok;
         Alcotest.(check string) "the page is untouched" before (read_file ctx "notes")))
    unstorable_tags

(* What was accepted reads back as what was sent: tags, and the body that
   follows the header. *)
let test_accepted_tags_read_back_unchanged () =
  with_temp_base_path (fun ctx ->
    let tags = [ "band"; "한글 태그"; "space inside"; "a:b"; "dash-ed" ] in
    create_ok ctx (create_args ~page:"tagged" ~tags ~body:"the body" ());
    Alcotest.(check (list string)) "tags after create" tags (frontmatter_of ctx "tagged").tags;
    let (ok, msg) =
      update ctx
        (update_args ~page:"tagged" ~base_revision:1 ~body:"the second body"
           ~tags:[ "song"; "두 번째" ] ())
    in
    Alcotest.(check bool) ("update succeeds: " ^ msg) true ok;
    Alcotest.(check (list string)) "tags after update" [ "song"; "두 번째" ]
      (frontmatter_of ctx "tagged").tags;
    let (_, read) =
      dispatch_exn ctx ~name:"masc_wiki_read" ~args:(`Assoc [ "topic", `String "tagged" ])
    in
    Alcotest.(check bool) "the body follows the header" true
      (String_util.contains_substring read "---\n\nthe second body\n"))

(* A value that is only spaces would be written and then read as a missing
   field. *)
let test_blank_header_values_are_refused () =
  with_temp_base_path (fun ctx ->
    let (ok, msg) = create ctx (create_args ~title:"   " ()) in
    Alcotest.(check bool) "blank title fails" false ok;
    Alcotest.(check bool) "names the title" true (msg_contains ~needle:"title is required" msg);
    let (ok, msg) = create ctx (create_args ~summary:" \t " ()) in
    Alcotest.(check bool) "blank summary fails" false ok;
    Alcotest.(check bool) "names the summary" true
      (msg_contains ~needle:"summary is required" msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx);
    create_ok ctx (create_args ~page:"notes" ());
    let before = read_file ctx "notes" in
    let (ok, _) = update ctx (update_args ~page:"notes" ~base_revision:1 ~body:"b" ~title:"  " ()) in
    Alcotest.(check bool) "blank new title fails" false ok;
    let (ok, msg) = update ctx (update_args ~page:"notes" ~base_revision:1 ~body:"b" ~note:"   " ()) in
    Alcotest.(check bool) "blank note fails" false ok;
    Alcotest.(check bool) "names the note" true (msg_contains ~needle:"note is required" msg);
    Alcotest.(check string) "the page is untouched" before (read_file ctx "notes"))

(* A page written by hand whose tags line is not a list is named with that
   reason. It is not listed with the pieces that happen to parse. *)
let test_a_tags_line_that_is_not_a_list_does_not_read () =
  with_temp_base_path (fun ctx ->
    write_wiki_page ctx ~filename:"open-bracket.md"
      "---\ntitle: Open Bracket\nsummary: s\nsource: research\nauthor: codex\n\
       created: 2026-10-13\nrevision: 1\ntags: [a, b\n---\n\nbody\n";
    let (ok, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check bool) "named with the reason" true
      (msg_contains ~needle:"- open-bracket.md (tags \"[a, b\" is not a list of tags)" listing);
    Alcotest.(check bool) "not listed as a page" false
      (msg_contains ~needle:"[Open Bracket]" listing))

(* ============================================================
   index.md and log.md
   ============================================================ *)

let own_file (ctx : Tool_wiki.context) name =
  let path = Filename.concat (Tool_wiki.wiki_root ~base_path:ctx.base_path) name in
  if Sys.file_exists path
  then In_channel.with_open_text path In_channel.input_all
  else ""

let lines_naming page text =
  String.split_on_char '\n' text
  |> List.filter (fun line -> String_util.contains_substring line page)

(* One create and two updates leave three lines in the log, oldest first, and
   one line in the index that follows the latest title and summary. *)
let test_every_write_adds_a_log_line_and_rebuilds_the_index () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"saju-palja" ~title:"사주팔자" ~summary:"first summary" ());
    let (ok, _) =
      update ctx
        (update_args ~page:"saju-palja" ~base_revision:1 ~body:"b2" ~note:"added the chords" ())
    in
    Alcotest.(check bool) "first update succeeds" true ok;
    let (ok, _) =
      update ctx
        (update_args ~page:"saju-palja" ~base_revision:2 ~body:"b3" ~summary:"latest summary"
           ~note:"compared it with YTN" ())
    in
    Alcotest.(check bool) "second update succeeds" true ok;
    let log = lines_naming "| saju-palja |" (own_file ctx "log.md") in
    Alcotest.(check int) "three log lines for the page" 3 (List.length log);
    (match log with
     | [ created; first; second ] ->
       Alcotest.(check bool) "create line" true
         (String_util.contains_substring created "] create r1 | saju-palja | test-agent | first summary");
       Alcotest.(check bool) "first update line" true
         (String_util.contains_substring first "] update r2 | saju-palja | test-agent | added the chords");
       Alcotest.(check bool) "second update line" true
         (String_util.contains_substring second "] update r3 | saju-palja | test-agent | compared it with YTN");
       List.iter
         (fun line ->
            Alcotest.(check bool) "starts the way grep expects" true
              (String.starts_with ~prefix:"## [" line))
         log
     | _ -> Alcotest.fail "expected exactly three lines");
    Alcotest.(check (list string)) "one index line for the page, with the latest summary"
      [ "- [사주팔자](saju-palja.md) — latest summary" ]
      (lines_naming "saju-palja.md" (own_file ctx "index.md")))

let test_index_lists_pages_in_name_order_with_unreadable_files () =
  with_temp_base_path (fun ctx ->
    write_wiki_page ctx ~filename:"hand.md" "---\ntitle: Hand Written\n---\n\nbody\n";
    create_ok ctx (create_args ~page:"ytn" ~title:"YTN" ~summary:"eleven-beat riff" ());
    create_ok ctx (create_args ~page:"bamseom" ~title:"밤섬" ~summary:"the closer" ());
    Alcotest.(check string) "the index"
      "# Wiki index\n\n\
       - [밤섬](bamseom.md) — the closer\n\
       - hand.md (no summary in frontmatter)\n\
       - [YTN](ytn.md) — eleven-beat riff\n"
      (own_file ctx "index.md");
    let (ok, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "list ok" true ok;
    Alcotest.(check string) "masc_wiki_list returns the same index" (own_file ctx "index.md") listing)

(* index.md and log.md sit beside the pages but are not pages: they are not
   listed, not found by read, and not returned by search. *)
let test_the_wikis_own_files_are_not_pages () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"only" ~title:"Only Page" ~body:"unique-marker" ());
    Alcotest.(check (list string)) "both files exist beside the page"
      [ "index.md"; "log.md"; "only.md" ]
      (List.sort String.compare (wiki_markdown_files ctx));
    let (_, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "index.md is not listed as a page" false
      (msg_contains ~needle:"index.md" listing);
    Alcotest.(check bool) "log.md is not listed as a page" false
      (msg_contains ~needle:"log.md" listing);
    let (ok, _) =
      dispatch_exn ctx ~name:"masc_wiki_read" ~args:(`Assoc [ "topic", `String "log" ])
    in
    Alcotest.(check bool) "log.md is not read as a page" false ok;
    let (_, results) =
      dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc [ "query", `String "only" ])
    in
    Alcotest.(check bool) "search returns the page" true
      (msg_contains ~needle:"only.md" results);
    Alcotest.(check bool) "search does not return the log" false
      (msg_contains ~needle:"log.md" results))

(* A refused write changes nothing, so it leaves no line. *)
let test_refused_writes_leave_no_log_line () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"notes" ());
    let before = own_file ctx "log.md" in
    let (ok, _) = create ctx (create_args ~page:"notes" ()) in
    Alcotest.(check bool) "create of an existing page fails" false ok;
    let (ok, _) = update ctx (update_args ~page:"notes" ~base_revision:7 ~body:"b" ()) in
    Alcotest.(check bool) "stale update fails" false ok;
    let (ok, _) = update ctx (update_args ~page:"notes" ~base_revision:1 ~body:"b" ~note:"two\nlines" ()) in
    Alcotest.(check bool) "multi-line note fails" false ok;
    Alcotest.(check string) "the log is unchanged" before (own_file ctx "log.md"))

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_wiki" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "all known tools dispatch" `Quick test_dispatch_all_known;
    ]);
    ("wiki_list", [
      Alcotest.test_case "empty list" `Quick test_list_empty;
    ]);
    ("wiki_read", [
      Alcotest.test_case "empty topic" `Quick test_read_empty_topic;
      Alcotest.test_case "nonexistent topic" `Quick test_read_nonexistent_topic;
      Alcotest.test_case "read by exact title (list->read contract)" `Quick test_read_by_title_roundtrip;
      Alcotest.test_case "read by case-insensitive partial title" `Quick test_read_by_title_case_insensitive_partial;
      Alcotest.test_case "read by page name" `Quick test_read_by_page_name;
    ]);
    ("wiki_create", [
      Alcotest.test_case "fresh base creates the wiki and reads the page" `Quick test_create_on_fresh_base;
      Alcotest.test_case "missing title" `Quick (test_create_missing_field "title");
      Alcotest.test_case "missing summary" `Quick (test_create_missing_field "summary");
      Alcotest.test_case "missing body" `Quick (test_create_missing_field "body");
      Alcotest.test_case "missing source" `Quick (test_create_missing_field "source");
      Alcotest.test_case "missing page" `Quick (test_create_missing_field "page");
      Alcotest.test_case "invalid source" `Quick test_create_invalid_source;
      Alcotest.test_case "blank author" `Quick test_create_with_blank_author_is_refused;
      Alcotest.test_case "wiki follows the context base path" `Quick test_wiki_follows_context_base_path;
      Alcotest.test_case "the file is named by page" `Quick test_create_names_the_file_by_page;
      Alcotest.test_case "two Korean titles do not collide" `Quick test_two_korean_titles_do_not_collide;
      Alcotest.test_case "an existing page is refused" `Quick test_create_refuses_an_existing_page;
      Alcotest.test_case "a bad page name is refused" `Quick test_create_refuses_a_bad_page_name;
      Alcotest.test_case "a multi-line title or summary is refused" `Quick test_create_refuses_a_multi_line_title_or_summary;
      Alcotest.test_case "schemas require what the handlers require" `Quick test_create_schema_requires_what_the_handler_requires;
    ]);
    ("wiki_update", [
      Alcotest.test_case "replaces the body and adds one to the revision" `Quick test_update_replaces_the_body_and_adds_one_to_the_revision;
      Alcotest.test_case "can change title, summary and tags" `Quick test_update_can_change_title_summary_and_tags;
      Alcotest.test_case "a stale update is refused with the current page" `Quick test_stale_update_is_refused_with_the_current_page;
      Alcotest.test_case "a page that does not exist is refused" `Quick test_update_refuses_a_page_that_does_not_exist;
      Alcotest.test_case "the source cannot change" `Quick test_update_cannot_change_the_source;
      Alcotest.test_case "missing base_revision" `Quick (test_update_missing_field "base_revision");
      Alcotest.test_case "missing body" `Quick (test_update_missing_field "body");
      Alcotest.test_case "missing note" `Quick (test_update_missing_field "note");
      Alcotest.test_case "a header that does not read is not rewritten" `Quick test_update_refuses_a_page_whose_header_does_not_read;
    ]);
    ("wiki_search", [
      Alcotest.test_case "empty query" `Quick test_search_empty_query;
      Alcotest.test_case "query is rejected at run time, not by the schema" `Quick test_search_schema_allows_runtime_query_rejection;
      Alcotest.test_case "finds a page by its body" `Quick test_search_finds_a_page_by_its_body;
    ]);
    ("index_and_log", [
      Alcotest.test_case "every write adds a log line and rebuilds the index" `Quick test_every_write_adds_a_log_line_and_rebuilds_the_index;
      Alcotest.test_case "the index lists pages in name order with unreadable files" `Quick test_index_lists_pages_in_name_order_with_unreadable_files;
      Alcotest.test_case "the wiki's own files are not pages" `Quick test_the_wikis_own_files_are_not_pages;
      Alcotest.test_case "refused writes leave no log line" `Quick test_refused_writes_leave_no_log_line;
    ]);
    ("header_values", [
      Alcotest.test_case "create refuses a tag that would not read back" `Quick test_create_refuses_a_tag_that_would_not_read_back;
      Alcotest.test_case "update refuses a tag that would not read back" `Quick test_update_refuses_a_tag_that_would_not_read_back;
      Alcotest.test_case "accepted tags read back unchanged" `Quick test_accepted_tags_read_back_unchanged;
      Alcotest.test_case "blank header values are refused" `Quick test_blank_header_values_are_refused;
      Alcotest.test_case "a tags line that is not a list does not read" `Quick test_a_tags_line_that_is_not_a_list_does_not_read;
    ]);
    ("unreadable", [
      Alcotest.test_case "unknown source is named, not passed through" `Quick test_unknown_source_is_named_not_passed_through;
      Alcotest.test_case "a header that does not read names its reason" `Quick test_header_that_does_not_read_names_its_reason;
    ]);
  ]
