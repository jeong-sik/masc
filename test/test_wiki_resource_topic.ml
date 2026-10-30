(** [masc://wiki/<topic>] resolves a topic against the wiki listing.

    The topic arrives from the client's URI. Before this suite it was
    concatenated onto the wiki directory and read, so [wiki/../<name>]
    reached a file outside the wiki directory. *)

let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

module Lib = Masc

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_wiki_resource" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp
;;

let rec rm_rf path =
  match Sys.is_directory path with
  | true ->
    Sys.readdir path |> Array.iter (fun e -> rm_rf (Filename.concat path e));
    Unix.rmdir path
  | false -> Sys.remove path
  | exception Sys_error _ -> ()
;;

let write path content =
  let oc = open_out path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)
;;

let read_resource state uri =
  let params = `Assoc [ "uri", `String uri ] in
  Lib.Mcp_server_eio_resource.handle_read_resource_eio state (`Int 1) (Some params)
;;

(* The handler answers either with contents or with a JSON-RPC error, so a
   test that only checked for absence of the secret would also pass on an
   error envelope. Return the served text so each case can say which. *)
let served_text json =
  let open Yojson.Safe.Util in
  match json |> member "result" with
  | `Null -> None (* JSON-RPC errors omit result. *)
  | result ->
    (match result |> member "contents" with
     | `List (entry :: _) ->
       (match entry |> member "text" with `String s -> Some s | _ -> None)
     | _ -> None)
;;

let with_wiki ?(documents = []) f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let wiki_dir = Lib.Tool_wiki.wiki_root ~base_path:dir in
       Unix.mkdir (Filename.dirname wiki_dir) 0o755;
       Unix.mkdir wiki_dir 0o755;
       write (Filename.concat wiki_dir "topic.md") "# Topic\n\nin the wiki.\n";
       List.iter
         (fun (name, body) -> write (Filename.concat wiki_dir name) body)
         documents;
       (* A sibling of .masc/, reachable only by climbing out of the wiki. *)
       write (Filename.concat dir "outside.md") "NOT-A-WIKI-PAGE\n";
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
       f state)
;;

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

let test_blocking_resource_io_uses_systhread () =
  Eio_main.run
  @@ fun _env ->
  match Lib.Mcp_server_eio_resource.For_testing.blocking_io_execution_context () with
  | Eio_guard.Non_eio -> ()
  | Eio_fiber -> fail "blocking resource I/O remained on the Eio fiber"
;;

let test_topic_in_the_wiki_is_served () =
  with_wiki (fun state ->
    match served_text (read_resource state "masc://wiki/topic") with
    | None -> fail "expected masc://wiki/topic to serve the document"
    | Some text ->
      check bool "serves the wiki page" true (contains text "in the wiki"))
;;

let test_topic_cannot_climb_out_of_the_wiki () =
  with_wiki (fun state ->
    let uri = "masc://wiki/../../outside" in
    let json = read_resource state uri in
    let open Yojson.Safe.Util in
    check (option string) "outside topic has no content" None (served_text json);
    check int "outside topic is a protocol error" (-32602)
      (json |> member "error" |> member "code" |> to_int);
    check string "outside topic error names the requested URI" uri
      (json |> member "error" |> member "data" |> member "uri" |> to_string))
;;

(* [wiki] without the separator is not a topic: [wikifoo] must not read as
   the topic [foo]. *)
let test_prefix_without_separator_is_not_a_topic () =
  with_wiki (fun state ->
    let json = read_resource state "masc://wikifoo" in
    let open Yojson.Safe.Util in
    let code = json |> member "error" |> member "code" in
    check bool "wikifoo is not a wiki resource" true (code = `Int (-32602)))
;;

let test_missing_topic_is_a_protocol_error () =
  with_wiki (fun state ->
    List.iter
      (fun uri ->
        let response = read_resource state uri in
        let open Yojson.Safe.Util in
        check (option string) (uri ^ " has no content") None (served_text response);
        check int (uri ^ " error code") (-32602)
          (response |> member "error" |> member "code" |> to_int);
        check string (uri ^ " error URI") uri
          (response |> member "error" |> member "data" |> member "uri" |> to_string))
      [ "masc://wiki/missing"; "masc://wiki/missing.json" ])
;;

(* A page can be listed and then fail to read: [list_pages] selects on the
   ".md" suffix alone, so a directory named like a page reaches the read and
   [load_file] raises [Sys_error] ("Is a directory"). The handler must answer
   with an error envelope instead of letting it escape, as the index and log
   branches already do — the [.mli] promises "Never raises". *)
let test_unreadable_page_answers_an_error_envelope () =
  with_wiki (fun state ->
    let base_path = (Lib.Mcp_server.workspace_config state).Lib.Workspace.base_path in
    let wiki_dir = Lib.Tool_wiki.wiki_root ~base_path in
    Unix.mkdir (Filename.concat wiki_dir "ghost.md") 0o755;
    List.iter
      (fun uri ->
        let response = read_resource state uri in
        check (option string) (uri ^ " has no content") None (served_text response);
        check int (uri ^ " error code") (-32602)
          Yojson.Safe.Util.(response |> member "error" |> member "code" |> to_int))
      [ "masc://wiki/ghost"; "masc://wiki/ghost.json" ])
;;

let test_missing_wiki_has_empty_json_index () =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
    let response = read_resource state "masc://wiki.json" in
    let body = Option.get (served_text response) |> Yojson.Safe.from_string in
    let open Yojson.Safe.Util in
    check int "empty document count" 0 (body |> member "count" |> to_int);
    check int "empty document list" 0 (body |> member "documents" |> to_list |> List.length))
;;

(* The resources read a page the way the wiki tools do. A document
   [masc_wiki_create] would write shows its source as the vocabulary word,
   not as a link; a document whose header does not read is named by filename
   with the tools' reason and is given no title, source, or fields the writer
   never writes. *)
let readable_document =
  "---\ntitle: Alpha Doc\nsummary: What alpha holds\nsource: research\nauthor: codex\n\
   created: 2026-09-22\nupdated: 2026-09-22\nrevision: 3\ntags: [alpha, keeper]\n---\nAlpha body\n"
;;

let url_source_document =
  "---\ntitle: Beta Doc\nsummary: What beta holds\nsource: https://example.com/beta\nauthor: codex\n\
   created: 2026-09-22\nrevision: 1\ntags: []\n---\nBeta body\n"
;;

let beta_reason =
  "source \"https://example.com/beta\" is not one of: direct_experience, research, \
   experiment, observation"
;;

let contract_documents =
  [ "alpha.md", readable_document; "beta.md", url_source_document ]
;;

let json_text state uri =
  match served_text (read_resource state uri) with
  | Some text -> Yojson.Safe.from_string text
  | None -> failf "expected %s to serve JSON" uri
;;

let keys = function
  | `Assoc fields -> List.map fst fields
  | _ -> fail "expected a JSON object"
;;

let document_named topic json =
  let open Yojson.Safe.Util in
  match
    List.find_opt
      (fun doc -> doc |> member "topic" = `String topic)
      (json |> member "documents" |> to_list)
  with
  | Some doc -> doc
  | None -> failf "no document %s in the JSON index" topic
;;

let test_markdown_index_follows_the_tool_contract () =
  with_wiki ~documents:contract_documents (fun state ->
    match served_text (read_resource state "masc://wiki") with
    | None -> fail "expected masc://wiki to serve the index"
    | Some text ->
      check bool "readable document shows its source word" true
        (contains text "- **Alpha Doc** -- `masc://wiki/alpha` (research) -- `alpha`, `keeper`");
      check bool "no source is drawn as a link" false (contains text "](");
      check bool "unknown source named by filename and reason" true
        (contains text ("- beta.md (" ^ beta_reason ^ ") -- `masc://wiki/beta`"));
      check bool "unknown-source document is given no title" false
        (contains text "**Beta Doc**");
      check bool "document without frontmatter named" true
        (contains text "- topic.md (no frontmatter) -- `masc://wiki/topic`"))
;;

let test_json_index_carries_written_fields_only () =
  with_wiki ~documents:contract_documents (fun state ->
    let json = json_text state "masc://wiki.json" in
    let alpha = document_named "alpha" json in
    check (list string) "readable document fields"
      [ "topic"; "title"; "summary"; "source"; "author"; "created"; "revision"; "tags"; "uri" ]
      (keys alpha);
    check string "source is the vocabulary word" "research"
      Yojson.Safe.Util.(alpha |> member "source" |> to_string);
    check string "summary is served" "What alpha holds"
      Yojson.Safe.Util.(alpha |> member "summary" |> to_string);
    check int "revision is served" 3
      Yojson.Safe.Util.(alpha |> member "revision" |> to_int);
    let beta = document_named "beta" json in
    check (list string) "unreadable document fields" [ "topic"; "unreadable"; "uri" ]
      (keys beta);
    check string "unreadable carries the reason" beta_reason
      Yojson.Safe.Util.(beta |> member "unreadable" |> to_string))
;;

let test_json_topic_of_an_unreadable_document () =
  with_wiki ~documents:contract_documents (fun state ->
    let json = json_text state "masc://wiki/beta.json" in
    check (list string) "fields" [ "topic"; "unreadable"; "content" ] (keys json);
    check string "content is served" "Beta body"
      Yojson.Safe.Util.(json |> member "content" |> to_string))
;;

(* A client that only lists resources cannot expand the [masc://wiki/{topic}]
   template, so the listing names each page itself and the log beside them. *)
let listed state =
  let base_path = (Lib.Mcp_server.workspace_config state).Lib.Workspace.base_path in
  Lib.Mcp_server_eio_resource.wiki_resources ~base_path
;;

let find_listed uri resources =
  List.find_opt
    (fun (resource : Lib.Mcp_server.mcp_resource) -> String.equal resource.uri uri)
    resources
;;

let test_pages_are_listed_with_title_and_summary () =
  with_wiki ~documents:contract_documents (fun state ->
    match find_listed "masc://wiki/alpha" (listed state) with
    | None -> fail "expected masc://wiki/alpha to be listed"
    | Some resource ->
      check (option string) "title is the page title" (Some "Alpha Doc") resource.title;
      check string "description is the page summary" "What alpha holds" resource.description;
      check string "pages are markdown" "text/markdown" resource.mime_type)
;;

let test_unreadable_page_is_listed_by_file_with_reason () =
  with_wiki ~documents:contract_documents (fun state ->
    match find_listed "masc://wiki/beta" (listed state) with
    | None -> fail "expected masc://wiki/beta to be listed"
    | Some resource ->
      check string "named by file" "beta.md" resource.name;
      (* [make_resource] titles a resource by its name when it has no title,
         so the file name stands in; no page title is invented for it. *)
      check (option string) "titled by its file name" (Some "beta.md") resource.title;
      check string "described by the reason" beta_reason resource.description)
;;

(* A page's body can be far larger than its header. The listing names it from
   the header and reports the whole file's size, which it takes from a stat
   rather than from reading the body (task-2309). *)
let test_large_page_is_listed_from_header_and_stat () =
  let header =
    "---\ntitle: Big Doc\nsummary: A body far larger than the header bound\n\
     source: research\nauthor: codex\ncreated: 2026-10-13\nrevision: 1\ntags: []\n---\n"
  in
  let body = "\n" ^ String.make 40000 'x' in
  with_wiki ~documents:[ "big.md", header ^ body ] (fun state ->
    match find_listed "masc://wiki/big" (listed state) with
    | None -> fail "expected masc://wiki/big to be listed"
    | Some resource ->
      check (option string) "title comes from the header" (Some "Big Doc") resource.title;
      check (option int) "size is the whole file, from a stat"
        (Some (String.length header + String.length body)) resource.size)
;;

(* A header longer than the read bound still parses: the listing falls back to
   the whole file rather than reporting the header unreadable. The summary
   alone is longer than the bound. *)
let test_header_longer_than_the_bound_still_parses () =
  let long_summary = String.make 9000 's' in
  let header =
    "---\ntitle: Long Doc\nsummary: " ^ long_summary
    ^ "\nsource: research\nauthor: codex\ncreated: 2026-10-13\nrevision: 1\ntags: []\n---\n"
  in
  with_wiki ~documents:[ "long.md", header ^ "body\n" ] (fun state ->
    match find_listed "masc://wiki/long" (listed state) with
    | None -> fail "expected masc://wiki/long to be listed"
    | Some resource ->
      check (option string) "title comes from the whole header" (Some "Long Doc")
        resource.title)
;;

(* A file whose name is not a valid page topic would resolve to a different
   page or to nothing, so it must not become a listing row: every listed page
   URI reads back as the file it was made from. *)
let test_only_round_trippable_pages_are_listed () =
  let bad_name_documents =
    [ "notes.json.md", "# not a page\n"
    ; "release notes.md", "# not a page\n"
    ; "a?b.md", "# not a page\n"
    ; "a#b.md", "# not a page\n" ]
  in
  with_wiki ~documents:(bad_name_documents @ contract_documents) (fun state ->
    let resources = listed state in
    List.iter
      (fun file ->
        let uri = "masc://wiki/" ^ Filename.chop_suffix file ".md" in
        check bool (file ^ " is not listed") true
          (Option.is_none (find_listed uri resources)))
      [ "notes.json.md"; "release notes.md"; "a?b.md"; "a#b.md" ];
    List.iter
      (fun (resource : Lib.Mcp_server.mcp_resource) ->
        match served_text (read_resource state resource.uri) with
        | None -> fail ("listed uri does not serve: " ^ resource.uri)
        | Some _ -> ())
      resources)
;;

let test_log_is_listed_and_served_once_it_exists () =
  let log = "## [2026-10-13 10:00] create r1 | alpha | codex | first\n" in
  with_wiki ~documents:(("log.md", log) :: contract_documents) (fun state ->
    (match find_listed "masc://wiki/log" (listed state) with
     | None -> fail "expected masc://wiki/log to be listed"
     | Some resource ->
       check (option string) "log title" (Some "Wiki log") resource.title;
       check string "log is markdown" "text/markdown" resource.mime_type);
    match served_text (read_resource state "masc://wiki/log") with
    | None -> fail "expected the log to be served"
    | Some text -> check string "the log file is served as written" log text)
;;

(* The log is append-only and grows without bound, so an explicit read returns
   its tail, not the whole file (task-2309). The listing still reports the
   whole-file size, so a client can tell a tail from the whole. *)
let test_a_large_log_is_served_from_its_tail () =
  let line i =
    Printf.sprintf "## [2026-10-13 10:00] update r%d | alpha | codex | note %d\n" i i
  in
  let buffer = Buffer.create 131072 in
  for i = 1 to 3000 do
    Buffer.add_string buffer (line i)
  done;
  let log = Buffer.contents buffer in
  let full = String.length log in
  check bool "the fixture log exceeds the read bound" true (full > 65536);
  with_wiki ~documents:(("log.md", log) :: contract_documents) (fun state ->
    match served_text (read_resource state "masc://wiki/log") with
    | None -> fail "expected the log to be served"
    | Some served ->
      let served_len = String.length served in
      check bool "the tail is shorter than the file" true (served_len < full);
      check string "the tail is a suffix of the file"
        (String.sub log (full - served_len) served_len)
        served;
      check char "the tail starts at a line boundary" '\n' log.[(full - served_len) - 1];
      let last = line 3000 in
      let last_len = String.length last in
      check bool "the tail ends with the last line" true
        (served_len >= last_len
         && String.sub served (served_len - last_len) last_len = last))
;;

let test_log_is_neither_listed_nor_served_without_a_log_file () =
  with_wiki ~documents:contract_documents (fun state ->
    check bool "no log entry" true
      (Option.is_none (find_listed "masc://wiki/log" (listed state)));
    let response = read_resource state "masc://wiki/log" in
    check (option string) "no log content" None (served_text response);
    check int "a missing log is a protocol error" (-32602)
      Yojson.Safe.Util.(response |> member "error" |> member "code" |> to_int))
;;

(* [index.md] and [log.md] are the wiki's own files. The index has its own
   resource, [masc://wiki], so the file is not a page under a second URI. *)
let test_own_index_file_is_not_a_listed_page () =
  with_wiki ~documents:(("index.md", "# Wiki index\n") :: contract_documents) (fun state ->
    check bool "index.md is not listed as a page" true
      (Option.is_none (find_listed "masc://wiki/index" (listed state)));
    check (option string) "index.md is not served as a page" None
      (served_text (read_resource state "masc://wiki/index")))
;;

let test_missing_wiki_lists_nothing () =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    check int "no wiki directory lists no resources" 0
      (List.length (Lib.Mcp_server_eio_resource.wiki_resources ~base_path:dir)))
;;

(* A regular file where the wiki directory belongs makes [list_pages] raise
   [Sys_error]. The resource reads answer the error envelope and the listing
   has no wiki pages, instead of the exception escaping resources/read or
   resources/list. *)
let with_file_as_wiki_root f =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    let wiki_dir = Lib.Tool_wiki.wiki_root ~base_path:dir in
    Unix.mkdir (Filename.dirname wiki_dir) 0o755;
    write wiki_dir "not a directory\n";
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let state = Lib.Mcp_server_eio.For_testing.create_state ~base_path:dir () in
    f state)
;;

let test_unlistable_wiki_root_answers_an_error_envelope () =
  with_file_as_wiki_root (fun state ->
    List.iter
      (fun uri ->
        let response = read_resource state uri in
        check (option string) (uri ^ " has no content") None (served_text response);
        check bool (uri ^ " is a JSON-RPC error") true
          (Yojson.Safe.Util.(response |> member "error") <> `Null))
      [ "masc://wiki"; "masc://wiki.json"; "masc://wiki/topic"; "masc://wiki/topic.json" ])
;;

let test_unlistable_wiki_root_lists_no_pages () =
  with_file_as_wiki_root (fun state ->
    check int "no wiki pages" 0 (List.length (listed state)))
;;

let () =
  run
    "wiki_resource_topic"
    [ ( "document contract"
      , [ test_case
            "markdown index follows the tool contract"
            `Quick
            test_markdown_index_follows_the_tool_contract
        ; test_case
            "JSON index carries written fields only"
            `Quick
            test_json_index_carries_written_fields_only
        ; test_case
            "JSON topic of an unreadable document"
            `Quick
            test_json_topic_of_an_unreadable_document
        ] )
    ; ( "topic resolution"
      , [ test_case "a topic in the listing is served" `Quick test_topic_in_the_wiki_is_served
        ; test_case
            "blocking resource I/O uses a system thread"
            `Quick
            test_blocking_resource_io_uses_systhread
        ; test_case
            "a topic cannot climb out of the wiki directory"
            `Quick
            test_topic_cannot_climb_out_of_the_wiki
        ; test_case
            "wiki without a separator is not a topic"
            `Quick
            test_prefix_without_separator_is_not_a_topic
        ; test_case "missing topic is a protocol error" `Quick test_missing_topic_is_a_protocol_error
        ; test_case "missing wiki has an empty JSON index" `Quick test_missing_wiki_has_empty_json_index
        ; test_case
            "an unreadable page answers an error envelope"
            `Quick
            test_unreadable_page_answers_an_error_envelope
        ] )
    ; ( "listing"
      , [ test_case
            "pages are listed with title and summary"
            `Quick
            test_pages_are_listed_with_title_and_summary
        ; test_case
            "an unreadable page is listed by file with the reason"
            `Quick
            test_unreadable_page_is_listed_by_file_with_reason
        ; test_case
            "a large page is listed from its header and a stat"
            `Quick
            test_large_page_is_listed_from_header_and_stat
        ; test_case
            "a header longer than the read bound still parses"
            `Quick
            test_header_longer_than_the_bound_still_parses
        ; test_case
            "only round-trippable pages are listed"
            `Quick
            test_only_round_trippable_pages_are_listed
        ; test_case
            "the log is listed and served once it exists"
            `Quick
            test_log_is_listed_and_served_once_it_exists
        ; test_case
            "the log is neither listed nor served without a log file"
            `Quick
            test_log_is_neither_listed_nor_served_without_a_log_file
        ; test_case
            "a large log is served from its tail"
            `Quick
            test_a_large_log_is_served_from_its_tail
        ; test_case
            "the index file is not a listed page"
            `Quick
            test_own_index_file_is_not_a_listed_page
        ; test_case "a missing wiki lists nothing" `Quick test_missing_wiki_lists_nothing
        ; test_case
            "an unlistable wiki root lists no pages"
            `Quick
            test_unlistable_wiki_root_lists_no_pages
        ; test_case
            "an unlistable wiki root answers an error envelope"
            `Quick
            test_unlistable_wiki_root_answers_an_error_envelope
        ] )
    ]
;;
