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
  let root = Tool_wiki.wiki_root ~base_path in
  Unix.mkdir (Filename.dirname root) 0o755;
  Unix.mkdir root 0o755;
  root

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

let line (value : Tool_wiki.Line.t) = (value :> string)
let tag_strings (tags : Tool_wiki.Tag.t list) = (tags :> string list)

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

(* The wiki is state the server writes for its world, so it sits under the
   workspace's [.masc/] with the rest and leaves the workspace's own [docs/]
   alone: there its pages were untracked files of the workspace's repository. *)
let test_pages_live_under_the_masc_directory () =
  with_temp_base_path ~prepare_wiki:false (fun ctx ->
    create_ok ctx (create_args ~page:"placed" ());
    Alcotest.(check bool) "the page is under .masc/wiki" true
      (Sys.file_exists (Filename.concat ctx.base_path ".masc/wiki/placed.md"));
    Alcotest.(check bool) "its index is beside it" true
      (Sys.file_exists (Filename.concat ctx.base_path ".masc/wiki/index.md"));
    Alcotest.(check bool) "nothing is written under docs" false
      (Sys.file_exists (Filename.concat ctx.base_path "docs")))

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

(* The index names a page by its file name without .md. A longer name that
   contains it sorts first here, and must not be opened instead. *)
let test_read_prefers_the_page_named_exactly () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"pm-setlist" ~title:"PM Setlist" ~body:"Body of the PM page." ());
    create_ok ctx
      (create_args ~page:"setlist" ~title:"Setlist" ~body:"Body of the plain page." ());
    let read_args = `Assoc [("topic", `String "setlist")] in
    let (ok, msg) = dispatch_exn ctx ~name:"masc_wiki_read" ~args:read_args in
    Alcotest.(check bool) "read succeeds" true ok;
    Alcotest.(check bool) "opens the page of that name" true
      (msg_contains ~needle:"Body of the plain page." msg);
    Alcotest.(check bool) "not the longer name" false
      (msg_contains ~needle:"Body of the PM page." msg)
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
    Alcotest.(check string) "title kept as written" "사주팔자" (line frontmatter.title);
    Alcotest.(check string) "summary kept" "One line about the page"
      (line frontmatter.summary);
    Alcotest.(check int) "starts at revision 1" 1 frontmatter.revision;
    Alcotest.(check string) "author is the caller" "test-agent" (line frontmatter.author);
    Alcotest.(check (list string)) "tags kept" [ "band"; "song" ]
      (tag_strings frontmatter.tags))

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
    Alcotest.(check string) "title kept" (line created.title) (line updated.title);
    Alcotest.(check string) "summary kept" (line created.summary) (line updated.summary);
    Alcotest.(check string) "author kept" (line created.author) (line updated.author);
    Alcotest.(check string) "created kept" (line created.created) (line updated.created);
    Alcotest.(check bool) "source kept" true (created.source = updated.source);
    Alcotest.(check (list string)) "tags kept" (tag_strings created.tags) (tag_strings updated.tags))

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
    Alcotest.(check string) "title changed" "새 제목" (line updated.title);
    Alcotest.(check string) "summary changed" "new summary" (line updated.summary);
    Alcotest.(check (list string)) "tags changed" [ "x"; "y" ] (tag_strings updated.tags))

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

(* Where [needle] first appears in [haystack], for ordering checks. *)
let position_of ~needle haystack =
  try Some (Str.search_forward (Str.regexp_string needle) haystack 0)
  with Not_found -> None

(* How many times [needle] appears in [haystack]. *)
let count_occurrences ~needle haystack =
  let re = Str.regexp_string needle in
  let rec count from acc =
    match Str.search_forward re haystack from with
    | at -> count (at + String.length needle) (acc + 1)
    | exception Not_found -> acc
  in
  count 0 0

(* The query was read as one run of text, so two words that are not adjacent in
   the page answered "No pages matching" although both were there. *)
let test_search_finds_a_page_holding_every_word_in_any_order () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"kr" ~title:"Korean Page"
         ~body:"정치병자의 곡은 박자가 자주 바뀌어요" ());
    create_ok ctx
      (create_args ~page:"partial" ~title:"Partial Page"
         ~body:"정치병자의 곡 목록만 있어요" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search"
        ~args:(`Assoc [ "query", `String "정치병자 박자" ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "names the page holding both words" true
      (msg_contains ~needle:"**Korean Page** kr.md" msg);
    Alcotest.(check bool) "leaves out the page missing one word" false
      (msg_contains ~needle:"Partial Page" msg);
    let (_, reversed) =
      dispatch_exn ctx ~name:"masc_wiki_search"
        ~args:(`Assoc [ "query", `String "박자 정치병자" ])
    in
    Alcotest.(check bool) "word order does not matter" true
      (msg_contains ~needle:"**Korean Page** kr.md" reversed))

let test_search_names_no_page_when_one_word_is_missing () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"one" ~body:"the beat changes often" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search"
        ~args:(`Assoc [ "query", `String "beat bassline" ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "says nothing matched" true
      (msg_contains ~needle:"No pages matching" msg))

(* "gap" sorts before "phrase" by name, so only the tier can put "phrase"
   first. *)
let test_search_lists_whole_query_matches_before_every_word_matches () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"gap" ~title:"Gap Page" ~body:"the root of the note" ());
    create_ok ctx
      (create_args ~page:"phrase" ~title:"Phrase Page" ~body:"the root note is C" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search"
        ~args:(`Assoc [ "query", `String "root note" ])
    in
    Alcotest.(check bool) "search ok" true ok;
    (match position_of ~needle:"Phrase Page" msg, position_of ~needle:"Gap Page" msg with
     | Some phrase, Some gap ->
       Alcotest.(check bool) "the page with the whole query comes first" true (phrase < gap)
     | _ -> Alcotest.fail ("both pages should match: " ^ msg));
    (* A page that holds the whole query also holds every word of it; it is
       listed once, in the first tier only. *)
    Alcotest.(check int) "the whole-query page is listed once" 1
      (count_occurrences ~needle:"Phrase Page" msg);
    Alcotest.(check int) "the every-word page is listed once" 1
      (count_occurrences ~needle:"Gap Page" msg))

(* A query of only spaces holds no word. It used to match a page that happened
   to contain that many spaces in a row. *)
let test_search_with_only_spaces_matches_no_page () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"spaced" ~title:"Spaced Page" ~body:"a   b" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc [ "query", `String "   " ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "says nothing matched" true
      (msg_contains ~needle:"No pages matching" msg);
    Alcotest.(check bool) "does not list the page with spaces" false
      (msg_contains ~needle:"Spaced Page" msg))

(* A term of one or two ASCII letters matches at a word boundary, so "ci"
   finds "CI" and not "decision". The memory search applies the same rule
   through [String_util.contains_query_term_ci]. *)
let test_search_matches_a_short_ascii_word_at_word_boundaries () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"ci" ~title:"Ci Page" ~body:"CI passes" ());
    create_ok ctx
      (create_args ~page:"decision" ~title:"Decision Page" ~body:"a decision was made" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc [ "query", `String "ci" ])
    in
    Alcotest.(check bool) "search ok" true ok;
    Alcotest.(check bool) "finds the page with the word" true
      (msg_contains ~needle:"Ci Page" msg);
    Alcotest.(check bool) "leaves out a word that only contains it" false
      (msg_contains ~needle:"Decision Page" msg))

(* Both pages hold the whole query, so name order would list "few" first. The
   page that says it four times in a few words comes first by relevance. *)
let test_search_lists_the_closest_page_first_inside_a_tier () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"few" ~title:"Few Page"
         ~body:"박자는 한 번 나오고 나머지는 베이스와 근음 이야기가 길게 이어져요" ());
    create_ok ctx
      (create_args ~page:"many" ~title:"Many Page" ~body:"박자 박자 박자 박자" ());
    let (ok, msg) =
      dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc [ "query", `String "박자" ])
    in
    Alcotest.(check bool) "search ok" true ok;
    match position_of ~needle:"Many Page" msg, position_of ~needle:"Few Page" msg with
    | Some many, Some few ->
      Alcotest.(check bool) "the page that says it more comes first" true (many < few)
    | _ -> Alcotest.fail ("both pages should match: " ^ msg))

(* A reader asks about a subject. author, source and the other header lines
   say who wrote the page and how, so they are not searched when the header
   reads. Tags are. *)
let test_search_reads_title_summary_tags_and_body_not_the_rest_of_the_header () =
  with_temp_base_path (fun ctx ->
    create_ok ctx
      (create_args ~page:"band" ~title:"Band Page" ~body:"박자 이야기" ~tags:[ "groove" ] ());
    let search query =
      let (ok, msg) =
        dispatch_exn ctx ~name:"masc_wiki_search" ~args:(`Assoc [ "query", `String query ])
      in
      Alcotest.(check bool) "search ok" true ok;
      msg
    in
    Alcotest.(check bool) "the author line is not searched" true
      (msg_contains ~needle:"No pages matching" (search "test-agent"));
    Alcotest.(check bool) "the source line is not searched" true
      (msg_contains ~needle:"No pages matching" (search "research"));
    Alcotest.(check bool) "a tag is searched" true
      (msg_contains ~needle:"**Band Page** band.md" (search "groove"));
    Alcotest.(check bool) "the title is searched" true
      (msg_contains ~needle:"**Band Page** band.md" (search "band page")))

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
   Header values
   ============================================================

   A header value is one line, [key: value], read back trimmed. The tags line
   is [tags: \[a, b\]]. The writers take only values that come back as they
   went in ([Tool_wiki.Line.t], [Tool_wiki.Tag.t]); anything else is refused
   when it is written, not cut down when it is read. *)

(* Every string of up to [max_length] characters over [alphabet]. *)
let strings_over alphabet ~max_length =
  let rec of_length n =
    if n = 0
    then [ "" ]
    else
      List.concat_map
        (fun shorter -> List.map (fun c -> shorter ^ String.make 1 c) alphabet)
        (of_length (n - 1))
  in
  List.concat_map of_length (List.init (max_length + 1) Fun.id)

let reads_back tags =
  Option.map tag_strings (Tool_wiki.Tag.of_line (Tool_wiki.Tag.to_line tags))

(* The rule in both directions, over every short string made of the
   characters the tags line gives a meaning to. A tag that is accepted reads
   back as itself, alone and beside another tag; a string that is refused
   would not have read back, so nothing is refused for no reason. *)
let test_a_tag_is_accepted_exactly_when_it_reads_back () =
  let candidates =
    strings_over [ 'a'; ' '; ','; '['; ']'; '\n'; '\r'; '\t' ] ~max_length:3
  in
  let accepted =
    List.filter_map
      (fun raw -> Result.to_option (Tool_wiki.Tag.of_string raw))
      candidates
  in
  Alcotest.(check bool) "some are accepted and some are refused" true
    (accepted <> [] && List.length accepted < List.length candidates);
  List.iter
    (fun raw ->
       let written = "[" ^ raw ^ "]" in
       let read = Option.map tag_strings (Tool_wiki.Tag.of_line written) in
       match Tool_wiki.Tag.of_string raw with
       | Ok tag ->
         Alcotest.(check (option (list string)))
           (Printf.sprintf "accepted tag %S reads back" raw)
           (Some [ raw ]) (reads_back [ tag ])
       | Error _ ->
         Alcotest.(check bool)
           (Printf.sprintf "refused tag %S would not have read back" raw)
           false
           (read = Some [ raw ]))
    candidates;
  List.iter
    (fun first ->
       List.iter
         (fun second ->
            Alcotest.(check (option (list string)))
              (Printf.sprintf "%S beside %S"
                 (first : Tool_wiki.Tag.t :> string)
                 (second : Tool_wiki.Tag.t :> string))
              (Some (tag_strings [ first; second ]))
              (reads_back [ first; second ]))
         accepted)
    accepted;
  Alcotest.(check (option (list string))) "no tags" (Some []) (reads_back [])

let unstorable_tags =
  [ "x\n---\nINJECTED"; "two\nlines"; "bare\rreturn"; "a,b"; " lead"; "trail "; "\ttab"
  ; ""; "   " ]

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

(* A refused tag leaves the page as it was. A blank one used to be dropped
   before anything looked at it, so sending only a blank tag emptied the
   page's tags. *)
let test_update_refuses_a_tag_that_would_not_read_back () =
  List.iter
    (fun tag ->
       with_temp_base_path (fun ctx ->
         create_ok ctx (create_args ~page:"notes" ~tags:[ "kept" ] ());
         let before = read_file ctx "notes" in
         let (ok, msg) =
           update ctx (update_args ~page:"notes" ~base_revision:1 ~body:"b" ~tags:[ tag ] ())
         in
         Alcotest.(check bool) (Printf.sprintf "tag %S is refused" tag) false ok;
         Alcotest.(check bool) "says the tag cannot be stored" true
           (msg_contains ~needle:"cannot be stored" msg);
         Alcotest.(check string) "the page is untouched" before (read_file ctx "notes")))
    unstorable_tags

(* [tags] that is not a list of strings is refused whole. *)
let test_tags_that_are_not_a_list_of_strings_are_refused () =
  let with_tags value = function
    | `Assoc fields -> `Assoc (("tags", value) :: List.remove_assoc "tags" fields)
    | other -> other
  in
  List.iter
    (fun (label, value) ->
       with_temp_base_path (fun ctx ->
         let (ok, msg) = create ctx (with_tags value (create_args ())) in
         Alcotest.(check bool) (label ^ " is refused on create") false ok;
         Alcotest.(check bool) "names the field" true
           (msg_contains ~needle:"tags must be a list of strings" msg);
         Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx);
         create_ok ctx (create_args ~page:"notes" ~tags:[ "kept" ] ());
         let before = read_file ctx "notes" in
         let (ok, _) =
           update ctx
             (with_tags value (update_args ~page:"notes" ~base_revision:1 ~body:"b" ()))
         in
         Alcotest.(check bool) (label ^ " is refused on update") false ok;
         Alcotest.(check string) "the page is untouched" before (read_file ctx "notes")))
    [ "a number among the tags", `List [ `String "ok"; `Int 3 ]
    ; "one string", `String "a, b"
    ; "null", `Null
    ]

(* What was accepted reads back as what was sent: tags, and the body that
   follows the header. A bracket inside a tag is one of its characters. *)
let test_accepted_tags_read_back_unchanged () =
  with_temp_base_path (fun ctx ->
    let tags =
      [ "band"; "한글 태그"; "space inside"; "a:b"; "dash-ed"; "c[1]"; "[wip]"; "]"
      ; "\"quoted\""; "#hash" ]
    in
    create_ok ctx (create_args ~page:"tagged" ~tags ~body:"the body" ());
    Alcotest.(check (list string)) "tags after create" tags
      (tag_strings (frontmatter_of ctx "tagged").tags);
    let (ok, msg) =
      update ctx
        (update_args ~page:"tagged" ~base_revision:1 ~body:"the second body"
           ~tags:[ "song"; "두 번째" ] ())
    in
    Alcotest.(check bool) ("update succeeds: " ^ msg) true ok;
    Alcotest.(check (list string)) "tags after update" [ "song"; "두 번째" ]
      (tag_strings (frontmatter_of ctx "tagged").tags);
    let (ok, msg) =
      update ctx (update_args ~page:"tagged" ~base_revision:2 ~body:"third" ~tags:[] ())
    in
    Alcotest.(check bool) ("an empty list clears the tags: " ^ msg) true ok;
    Alcotest.(check (list string)) "no tags" [] (tag_strings (frontmatter_of ctx "tagged").tags);
    let (_, read) =
      dispatch_exn ctx ~name:"masc_wiki_read" ~args:(`Assoc [ "topic", `String "tagged" ])
    in
    Alcotest.(check bool) "the body follows the header" true
      (String_util.contains_substring read "---\n\nthird\n"))

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

(* The reader trims a value, so a title sent with a space at either end would
   read back as a different title. *)
let test_whitespace_around_a_header_value_is_refused () =
  let refusal name = name ^ " may not start or end with whitespace" in
  with_temp_base_path (fun ctx ->
    let (ok, msg) = create ctx (create_args ~title:"  Title  " ()) in
    Alcotest.(check bool) "title with outer spaces fails" false ok;
    Alcotest.(check bool) "names the title" true (msg_contains ~needle:(refusal "title") msg);
    let (ok, msg) = create ctx (create_args ~summary:"\tsummary" ()) in
    Alcotest.(check bool) "summary with a leading tab fails" false ok;
    Alcotest.(check bool) "names the summary" true
      (msg_contains ~needle:(refusal "summary") msg);
    Alcotest.(check (list string)) "no page written" [] (wiki_pages ctx);
    create_ok ctx (create_args ~page:"notes" ~title:"inner  spaces stay" ());
    Alcotest.(check string) "spaces inside a title are kept" "inner  spaces stay"
      (line (frontmatter_of ctx "notes").title);
    let before = read_file ctx "notes" in
    List.iter
      (fun (label, args, needle) ->
         let (ok, msg) = update ctx args in
         Alcotest.(check bool) (label ^ " fails") false ok;
         Alcotest.(check bool) (label ^ " is named") true (msg_contains ~needle msg))
      [ ( "new title with a trailing space"
        , update_args ~page:"notes" ~base_revision:1 ~body:"b" ~title:"New " ()
        , refusal "title" )
      ; ( "new summary with a leading space"
        , update_args ~page:"notes" ~base_revision:1 ~body:"b" ~summary:" new" ()
        , refusal "summary" )
      ; ( "note with a trailing space"
        , update_args ~page:"notes" ~base_revision:1 ~body:"b" ~note:"why " ()
        , refusal "note" )
      ];
    Alcotest.(check string) "the page is untouched" before (read_file ctx "notes"))

(* The caller's name is the [author] line and a field of the log line. *)
let test_a_caller_name_that_is_not_a_header_value_is_refused () =
  List.iter
    (fun (agent_name, needle) ->
       with_temp_base_path (fun ctx ->
         create_ok ctx (create_args ~page:"notes" ());
         let before = read_file ctx "notes" in
         let named = { ctx with Tool_wiki.agent_name } in
         let (ok, msg) = create named (create_args ~page:"second" ()) in
         Alcotest.(check bool) (Printf.sprintf "create as %S fails" agent_name) false ok;
         Alcotest.(check bool) "says why" true (msg_contains ~needle msg);
         Alcotest.(check (list string)) "no second page" [ "notes.md" ] (wiki_pages ctx);
         let (ok, msg) =
           update named (update_args ~page:"notes" ~base_revision:1 ~body:"b" ())
         in
         Alcotest.(check bool) (Printf.sprintf "update as %S fails" agent_name) false ok;
         Alcotest.(check bool) "says why" true (msg_contains ~needle msg);
         Alcotest.(check string) "the page is untouched" before (read_file ctx "notes")))
    [ "agent\n---\ntitle: taken", "agent name must be one line"
    ; "agent\rname", "agent name must be one line"
    ; " agent", "agent name may not start or end with whitespace"
    ]

let page_with_tags_line tags_line =
  Printf.sprintf
    "---\ntitle: By Hand\nsummary: s\nsource: research\nauthor: codex\n\
     created: 2026-10-13\nrevision: 1\n%s\n---\n\nbody\n"
    tags_line

(* A page written by hand whose tags line is not what the writer writes is
   named with that reason. It is not listed with the pieces that happen to
   parse. *)
let test_a_tags_line_that_is_not_a_list_does_not_read () =
  List.iter
    (fun (tags_line, value) ->
       with_temp_base_path (fun ctx ->
         write_wiki_page ctx ~filename:"by-hand.md" (page_with_tags_line tags_line);
         let (ok, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
         Alcotest.(check bool) "list ok" true ok;
         Alcotest.(check bool) (Printf.sprintf "%S is named with the reason" tags_line) true
           (msg_contains
              ~needle:(Printf.sprintf "- by-hand.md (tags \"%s\" is not a list of tags)" value)
              listing);
         Alcotest.(check bool) "not listed as a page" false
           (msg_contains ~needle:"[By Hand]" listing)))
    [ "tags: [a, b", "[a, b"
    ; "tags: a, b", "a, b"
    ; "tags: [a,, b]", "[a,, b]"
    ; "tags: [a, ]", "[a, ]"
    ; "tags:", ""
    ]

(* A bracket is not what makes a tags line unreadable: a page written before
   tags were checked, with a bracket inside a tag, still reads. *)
let test_a_tags_line_with_brackets_inside_a_tag_reads () =
  with_temp_base_path (fun ctx ->
    write_wiki_page ctx ~filename:"by-hand.md" (page_with_tags_line "tags: [c[1], [wip]]");
    Alcotest.(check (list string)) "both tags" [ "c[1]"; "[wip]" ]
      (tag_strings (frontmatter_of ctx "by-hand").tags);
    write_wiki_page ctx ~filename:"by-hand.md" (page_with_tags_line "tags: []");
    Alcotest.(check (list string)) "an empty list is no tags" []
      (tag_strings (frontmatter_of ctx "by-hand").tags))

(* No tool rewrites a page whose header does not read: read shows it with the
   reason and update refuses it, so a writer cannot paper over it unseen. *)
let test_a_page_whose_tags_do_not_read_is_shown_and_not_updated () =
  with_temp_base_path (fun ctx ->
    let content = page_with_tags_line "tags: [a, b" in
    write_wiki_page ctx ~filename:"by-hand.md" content;
    let (ok, read) =
      dispatch_exn ctx ~name:"masc_wiki_read" ~args:(`Assoc [ "topic", `String "by-hand" ])
    in
    Alcotest.(check bool) "read by file name" true ok;
    Alcotest.(check bool) "the heading carries the reason" true
      (msg_contains ~needle:"## by-hand.md (tags \"[a, b\" is not a list of tags)" read);
    let (ok, msg) =
      update ctx (update_args ~page:"by-hand" ~base_revision:1 ~body:"b" ~tags:[ "a" ] ())
    in
    Alcotest.(check bool) "update is refused" false ok;
    Alcotest.(check bool) "with the reason" true
      (msg_contains ~needle:"its header does not read (tags \"[a, b\" is not a list of tags)" msg);
    Alcotest.(check string) "the file is untouched" content (read_file ctx "by-hand"))

(* A carriage return inside a value is the one thing a reader's line can
   hold that a header value cannot. *)
let test_a_carriage_return_inside_a_value_does_not_read () =
  with_temp_base_path (fun ctx ->
    write_wiki_page ctx ~filename:"by-hand.md"
      "---\ntitle: one\rtwo\nsummary: s\nsource: research\nauthor: codex\n\
       created: 2026-10-13\nrevision: 1\ntags: []\n---\n\nbody\n";
    let (_, listing) = dispatch_exn ctx ~name:"masc_wiki_list" ~args:(`Assoc []) in
    Alcotest.(check bool) "named with the reason" true
      (msg_contains ~needle:"- by-hand.md (title in frontmatter is not one line)" listing))

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
   Two writers at once
   ============================================================

   Both writers read revision 1 and both send an update. Under Eio the page
   write hops to a system thread, so the first writer's fiber yields between
   its revision check and its write, and the second writer runs. The wiki lock
   is what keeps the second writer from reading revision 1 in that gap:
   without it both updates are accepted, both write revision 2, and one body
   is lost with no refusal to say so. *)
let test_two_writers_on_one_revision_do_not_both_win () =
  with_temp_base_path (fun ctx ->
    create_ok ctx (create_args ~page:"shared" ~body:"first body" ());
    let results =
      Eio_main.run (fun _env ->
        Eio.Fiber.List.map
          (fun writer ->
             update ctx
               (update_args ~page:"shared" ~base_revision:1 ~body:("body from " ^ writer)
                  ~note:("change by " ^ writer) ()))
          [ "writer-a"; "writer-b" ])
    in
    let accepted = List.filter (fun (ok, _) -> ok) results in
    let refused = List.filter (fun (ok, _) -> not ok) results in
    Alcotest.(check int) "exactly one update is accepted" 1 (List.length accepted);
    Alcotest.(check int) "the other is refused" 1 (List.length refused);
    List.iter
      (fun (_, msg) ->
         Alcotest.(check bool) "the refusal says where the page is now" true
           (String_util.contains_substring msg "is at revision 2, not 1"))
      refused;
    Alcotest.(check int) "the page is at revision 2" 2 (frontmatter_of ctx "shared").revision;
    Alcotest.(check int) "the log has one update line" 1
      (List.length (lines_naming "] update r" (own_file ctx "log.md"))))

(* ============================================================
   wiki_lint
   ============================================================ *)

let add_page ctx ~page ~body =
  let ok, message =
    dispatch_exn ctx ~name:"masc_wiki_create" ~args:(create_args ~page ~body ())
  in
  if not ok then Alcotest.failf "create %s: %s" page message

let lint_json ctx args =
  let ok, message = dispatch_exn ctx ~name:"masc_wiki_lint" ~args in
  Alcotest.(check bool) "lint succeeds" true ok;
  Yojson.Safe.from_string message

let lint_member json key = Yojson.Safe.Util.member key json

let tree_snapshot (ctx : Tool_wiki.context) =
  let root = Tool_wiki.wiki_root ~base_path:ctx.base_path in
  Sys.readdir root
  |> Array.to_list
  |> List.sort String.compare
  |> List.map (fun name ->
    name, Digest.file (Filename.concat root name) |> Digest.to_hex)

let test_lint_reports_and_does_not_write () =
  with_temp_base_path (fun ctx ->
    add_page ctx ~page:"alpha" ~body:"See [b](beta.md) and [gone](missing.md).\n\n## Sources\n- repo:lib/x.ml";
    add_page ctx ~page:"beta" ~body:"no links, no sources";
    write_wiki_page ctx ~filename:"torn.md" "no header at all";
    let before = tree_snapshot ctx in
    let json = lint_json ctx (`Assoc []) in
    Alcotest.(check string) "a second run is byte-identical"
      (Yojson.Safe.to_string json)
      (Yojson.Safe.to_string (lint_json ctx (`Assoc [])));
    Alcotest.(check string) "schema" "masc.wiki_lint.v1"
      Yojson.Safe.Util.(to_string (lint_member json "schema"));
    Alcotest.(check int) "pages_total" 3
      Yojson.Safe.Util.(to_int (lint_member json "pages_total"));
    Alcotest.(check int) "pages_unreadable" 1
      Yojson.Safe.Util.(to_int (lint_member json "pages_unreadable"));
    let kinds =
      Yojson.Safe.Util.(
        lint_member json "findings"
        |> to_list
        |> List.map (fun f -> to_string (member "kind" f)))
    in
    Alcotest.(check bool) "broken link present" true (List.mem "broken_link" kinds);
    Alcotest.(check bool) "unreadable page present" true
      (List.mem "unreadable_page" kinds);
    Alcotest.(check bool) "wiki untouched" true (before = tree_snapshot ctx))

let test_lint_lock_file_is_not_a_page () =
  with_temp_base_path (fun ctx ->
    add_page ctx ~page:"alpha" ~body:"x";
    write_wiki_page ctx ~filename:".wiki.lock" "";
    let json = lint_json ctx (`Assoc []) in
    Alcotest.(check int) "pages_total counts pages only" 1
      Yojson.Safe.Util.(to_int (lint_member json "pages_total"));
    Alcotest.(check int) "no unreadable page" 0
      Yojson.Safe.Util.(to_int (lint_member json "pages_unreadable")))

let test_lint_limit_and_cursor_walk_every_finding () =
  with_temp_base_path (fun ctx ->
    for i = 1 to 7 do
      add_page ctx ~page:(Printf.sprintf "p%d" i) ~body:"nothing"
    done;
    let rec walk cursor acc guard =
      if guard = 0 then Alcotest.fail "cursor did not terminate"
      else
        let args =
          `Assoc
            ([ "limit", `Int 3 ]
             @ match cursor with None -> [] | Some c -> [ "cursor", `String c ])
        in
        let json = lint_json ctx args in
        let n = List.length Yojson.Safe.Util.(to_list (lint_member json "findings")) in
        match lint_member json "next_cursor" with
        | `String c -> walk (Some c) (acc + n) (guard - 1)
        | _ -> acc + n
    in
    let whole =
      Yojson.Safe.Util.(
        to_int (lint_member (lint_json ctx (`Assoc [ "limit", `Int 200 ])) "matched"))
    in
    Alcotest.(check int) "pages cover matched" whole (walk None 0 50);
    Alcotest.(check bool) "has findings" true (whole > 3))

let test_lint_refuses_bad_arguments () =
  with_temp_base_path (fun ctx ->
    let refused args =
      let ok, _ = dispatch_exn ctx ~name:"masc_wiki_lint" ~args in
      Alcotest.(check bool) "refused" false ok
    in
    refused (`Assoc [ "kind", `String "nope" ]);
    refused (`Assoc [ "limit", `Int 0 ]);
    refused (`Assoc [ "cursor", `String "garbage" ]);
    refused (`Assoc [ "page", `String "../escape" ]);
    refused (`Assoc [ "limit", `String "20" ]);
    refused (`Assoc [ "limit", `Float 2.5 ]);
    refused (`Assoc [ "kind", `Int 5 ]);
    refused (`Assoc [ "cursor", `Int 1 ]))

let test_lint_stale_cursor_is_refused () =
  with_temp_base_path (fun ctx ->
    for i = 1 to 4 do
      add_page ctx ~page:(Printf.sprintf "p%d" i) ~body:"nothing"
    done;
    let first = lint_json ctx (`Assoc [ "limit", `Int 2 ]) in
    let cursor =
      match lint_member first "next_cursor" with
      | `String c -> c
      | _ -> Alcotest.fail "expected a next_cursor"
    in
    (* The caller fixes the first finding's page between the two calls. *)
    add_page ctx ~page:"p0" ~body:"[p1](p1.md) [p2](p2.md) [p3](p3.md) [p4](p4.md)";
    let ok, message =
      dispatch_exn ctx ~name:"masc_wiki_lint"
        ~args:(`Assoc [ "limit", `Int 2; "cursor", `String cursor ])
    in
    Alcotest.(check bool) "stale cursor refused" false ok;
    Alcotest.(check bool) "names both wiki and filter causes" true
      (msg_contains
         ~needle:"the wiki changed, or `kind`/`page` differ from the call that issued it"
         message);
    Alcotest.(check bool) "says to start again" true
      (msg_contains ~needle:"without cursor" message);
    (* The same cursor is honoured while the wiki and filter are unchanged, and
       refused with the same message when [kind] or [page] changes. *)
    let again = lint_json ctx (`Assoc [ "limit", `Int 2 ]) in
    match lint_member again "next_cursor" with
    | `String fresh ->
      let filter_changed_ok, filter_changed_message =
        dispatch_exn ctx ~name:"masc_wiki_lint"
          ~args:(`Assoc [ "limit", `Int 2; "page", `String "p1"; "cursor", `String fresh ])
      in
      Alcotest.(check bool) "cursor with changed page filter refused" false filter_changed_ok;
      Alcotest.(check bool) "filter-mismatch refusal names kind/page cause" true
        (msg_contains
           ~needle:"the wiki changed, or `kind`/`page` differ from the call that issued it"
           filter_changed_message);
      let ok, _ =
        dispatch_exn ctx ~name:"masc_wiki_lint"
          ~args:(`Assoc [ "limit", `Int 2; "cursor", `String fresh ])
      in
      Alcotest.(check bool) "fresh cursor accepted" true ok
    | _ -> Alcotest.fail "expected a next_cursor")

let test_lint_kind_enum_is_all_kinds () =
  let schema = required_schema "masc_wiki_lint" in
  let declared =
    match schema.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         (match List.assoc_opt "kind" props with
          | Some (`Assoc kind) ->
            (match List.assoc_opt "enum" kind with
             | Some (`List values) ->
               List.filter_map (function `String s -> Some s | _ -> None) values
             | _ -> Alcotest.fail "kind has no enum")
          | _ -> Alcotest.fail "no kind property")
       | _ -> Alcotest.fail "no properties")
    | _ -> Alcotest.fail "input_schema is not an object"
  in
  Alcotest.(check (list string)) "enum = Masc.Wiki_lint.all_kinds"
    Masc.Wiki_lint.all_kinds declared

(* A log.md that exists but cannot be read is an error, not an empty log. A
   directory at that path is the root-independent way to make the read fail:
   the file is there, so the tool must not answer "nothing is wrong". *)
let test_lint_reports_an_unreadable_log () =
  with_temp_base_path (fun ctx ->
    add_page ctx ~page:"alpha" ~body:"x";
    let path = Filename.concat (Tool_wiki.wiki_root ~base_path:ctx.base_path) "log.md" in
    (* The create above already wrote log.md (#43149); replace it with a
       directory to make the read fail. *)
    Unix.unlink path;
    Unix.mkdir path 0o755;
    let ok, message = dispatch_exn ctx ~name:"masc_wiki_lint" ~args:(`Assoc []) in
    Alcotest.(check bool) "an unreadable log is an error" false ok;
    Alcotest.(check bool) "says which file failed" true (msg_contains ~needle:"log.md" message);
    (* With no log.md at all the same call succeeds and reports zero. *)
    Unix.rmdir path;
    let ok, _ = dispatch_exn ctx ~name:"masc_wiki_lint" ~args:(`Assoc []) in
    Alcotest.(check bool) "no log.md yet is not an error" true ok)

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
      Alcotest.test_case "read prefers the page named exactly" `Quick test_read_prefers_the_page_named_exactly;
      Alcotest.test_case "read by page name" `Quick test_read_by_page_name;
    ]);
    ("wiki_create", [
      Alcotest.test_case "fresh base creates the wiki and reads the page" `Quick test_create_on_fresh_base;
      Alcotest.test_case "pages live under the .masc directory" `Quick test_pages_live_under_the_masc_directory;
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
      Alcotest.test_case "two writers on one revision do not both win" `Quick test_two_writers_on_one_revision_do_not_both_win;
      Alcotest.test_case "a header that does not read is not rewritten" `Quick test_update_refuses_a_page_whose_header_does_not_read;
    ]);
    ("wiki_search", [
      Alcotest.test_case "empty query" `Quick test_search_empty_query;
      Alcotest.test_case "query is rejected at run time, not by the schema" `Quick test_search_schema_allows_runtime_query_rejection;
      Alcotest.test_case "finds a page by its body" `Quick test_search_finds_a_page_by_its_body;
      Alcotest.test_case "finds a page holding every word in any order" `Quick test_search_finds_a_page_holding_every_word_in_any_order;
      Alcotest.test_case "names no page when one word is missing" `Quick test_search_names_no_page_when_one_word_is_missing;
      Alcotest.test_case "lists whole-query matches before every-word matches" `Quick test_search_lists_whole_query_matches_before_every_word_matches;
      Alcotest.test_case "matches a short ASCII word at word boundaries" `Quick test_search_matches_a_short_ascii_word_at_word_boundaries;
      Alcotest.test_case "a query of only spaces matches no page" `Quick test_search_with_only_spaces_matches_no_page;
      Alcotest.test_case "lists the closest page first inside a tier" `Quick test_search_lists_the_closest_page_first_inside_a_tier;
      Alcotest.test_case "reads title, summary, tags and body, not the rest of the header" `Quick test_search_reads_title_summary_tags_and_body_not_the_rest_of_the_header;
    ]);
    ("index_and_log", [
      Alcotest.test_case "every write adds a log line and rebuilds the index" `Quick test_every_write_adds_a_log_line_and_rebuilds_the_index;
      Alcotest.test_case "the index lists pages in name order with unreadable files" `Quick test_index_lists_pages_in_name_order_with_unreadable_files;
      Alcotest.test_case "the wiki's own files are not pages" `Quick test_the_wikis_own_files_are_not_pages;
      Alcotest.test_case "refused writes leave no log line" `Quick test_refused_writes_leave_no_log_line;
    ]);
    ("header_values", [
      Alcotest.test_case "a tag is accepted exactly when it reads back" `Quick test_a_tag_is_accepted_exactly_when_it_reads_back;
      Alcotest.test_case "create refuses a tag that would not read back" `Quick test_create_refuses_a_tag_that_would_not_read_back;
      Alcotest.test_case "update refuses a tag that would not read back" `Quick test_update_refuses_a_tag_that_would_not_read_back;
      Alcotest.test_case "tags that are not a list of strings are refused" `Quick test_tags_that_are_not_a_list_of_strings_are_refused;
      Alcotest.test_case "accepted tags read back unchanged" `Quick test_accepted_tags_read_back_unchanged;
      Alcotest.test_case "blank header values are refused" `Quick test_blank_header_values_are_refused;
      Alcotest.test_case "whitespace around a header value is refused" `Quick test_whitespace_around_a_header_value_is_refused;
      Alcotest.test_case "a caller name that is not a header value is refused" `Quick test_a_caller_name_that_is_not_a_header_value_is_refused;
      Alcotest.test_case "a tags line that is not a list does not read" `Quick test_a_tags_line_that_is_not_a_list_does_not_read;
      Alcotest.test_case "a tags line with brackets inside a tag reads" `Quick test_a_tags_line_with_brackets_inside_a_tag_reads;
      Alcotest.test_case "a page whose tags do not read is shown and not updated" `Quick test_a_page_whose_tags_do_not_read_is_shown_and_not_updated;
      Alcotest.test_case "a carriage return inside a value does not read" `Quick test_a_carriage_return_inside_a_value_does_not_read;
    ]);
    ("wiki_lint", [
      Alcotest.test_case "reports findings and writes nothing" `Quick test_lint_reports_and_does_not_write;
      Alcotest.test_case "the lock file is not a page" `Quick test_lint_lock_file_is_not_a_page;
      Alcotest.test_case "limit and cursor walk every finding" `Quick test_lint_limit_and_cursor_walk_every_finding;
      Alcotest.test_case "bad arguments are refused" `Quick test_lint_refuses_bad_arguments;
      Alcotest.test_case "a cursor from before the wiki changed is refused" `Quick test_lint_stale_cursor_is_refused;
      Alcotest.test_case "the kind enum is every kind" `Quick test_lint_kind_enum_is_all_kinds;
      Alcotest.test_case "an unreadable log is an error, not an empty log" `Quick
        test_lint_reports_an_unreadable_log;
    ]);
    ("unreadable", [
      Alcotest.test_case "unknown source is named, not passed through" `Quick test_unknown_source_is_named_not_passed_through;
      Alcotest.test_case "a header that does not read names its reason" `Quick test_header_that_does_not_read_names_its_reason;
    ]);
  ]
