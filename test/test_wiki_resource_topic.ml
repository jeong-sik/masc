(** [masc://wiki/<topic>] resolves a topic against the wiki listing.

    The topic arrives from the client's URI. Before this suite it was
    concatenated onto [docs/wiki] and read, so [wiki/../<name>]
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
       let wiki_dir = Filename.concat (Filename.concat dir "docs") "wiki" in
       Unix.mkdir (Filename.concat dir "docs") 0o755;
       Unix.mkdir wiki_dir 0o755;
       write (Filename.concat wiki_dir "topic.md") "# Topic\n\nin the wiki.\n";
       List.iter
         (fun (name, body) -> write (Filename.concat wiki_dir name) body)
         documents;
       (* A sibling of docs/, reachable only by climbing out of the wiki. *)
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
            "a topic cannot climb out of docs/wiki"
            `Quick
            test_topic_cannot_climb_out_of_the_wiki
        ; test_case
            "wiki without a separator is not a topic"
            `Quick
            test_prefix_without_separator_is_not_a_topic
        ; test_case "missing topic is a protocol error" `Quick test_missing_topic_is_a_protocol_error
        ; test_case "missing wiki has an empty JSON index" `Quick test_missing_wiki_has_empty_json_index
        ] )
    ]
;;
