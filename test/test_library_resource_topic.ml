(** [masc://library/<topic>] resolves a topic against the library listing.

    The topic arrives from the client's URI. Before this suite it was
    concatenated onto [docs/library] and read, so [library/../<name>]
    reached a file outside the library directory. *)

let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

module Lib = Masc

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_library_resource" "" in
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
  match json |> member "result" |> member "contents" with
  | `List (entry :: _) ->
    (match entry |> member "text" with `String s -> Some s | _ -> None)
  | _ -> None
;;

let with_library ?(documents = []) f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let library_dir = Filename.concat (Filename.concat dir "docs") "library" in
       Unix.mkdir (Filename.concat dir "docs") 0o755;
       Unix.mkdir library_dir 0o755;
       write (Filename.concat library_dir "topic.md") "# Topic\n\nin the library.\n";
       List.iter
         (fun (name, body) -> write (Filename.concat library_dir name) body)
         documents;
       (* A sibling of docs/, reachable only by climbing out of the library. *)
       write (Filename.concat dir "outside.md") "NOT-A-LIBRARY-DOCUMENT\n";
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

let test_topic_in_the_library_is_served () =
  with_library (fun state ->
    match served_text (read_resource state "masc://library/topic") with
    | None -> fail "expected masc://library/topic to serve the document"
    | Some text ->
      check bool "serves the library document" true (contains text "in the library"))
;;

let test_topic_cannot_climb_out_of_the_library () =
  with_library (fun state ->
    let json = read_resource state "masc://library/../../outside" in
    match served_text json with
    | None -> ()
    | Some text ->
      check
        bool
        "a topic that climbs out of docs/library must not be served"
        false
        (contains text "NOT-A-LIBRARY-DOCUMENT"))
;;

(* [library] used to be matched as a bare prefix and the remainder taken from
   a fixed offset of 8, so [libraryfoo] was read as the topic [oo]. *)
let test_prefix_without_separator_is_not_a_topic () =
  with_library (fun state ->
    let json = read_resource state "masc://libraryfoo" in
    let open Yojson.Safe.Util in
    let code = json |> member "error" |> member "code" in
    check bool "libraryfoo is not a library resource" true (code = `Int (-32002)))
;;

(* The resources read a document the way the library tools do. A document
   [masc_library_add] would write shows its source as the vocabulary word,
   not as a link; a document whose header does not read is named by filename
   with the tools' reason and is given no title, source, or fields the writer
   never writes. *)
let readable_document =
  "---\ntitle: Alpha Doc\nsource: research\nauthor: codex\ncreated: 2026-09-22\n\
   updated: 2026-09-22\ntags: [alpha, keeper]\n---\nAlpha body\n"
;;

let url_source_document =
  "---\ntitle: Beta Doc\nsource: https://example.com/beta\nauthor: codex\n\
   created: 2026-09-22\ntags: []\n---\nBeta body\n"
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
  with_library ~documents:contract_documents (fun state ->
    match served_text (read_resource state "masc://library") with
    | None -> fail "expected masc://library to serve the index"
    | Some text ->
      check bool "readable document shows its source word" true
        (contains text "- **Alpha Doc** -- `masc://library/alpha` (research) -- `alpha`, `keeper`");
      check bool "no source is drawn as a link" false (contains text "](");
      check bool "unknown source named by filename and reason" true
        (contains text ("- beta.md (" ^ beta_reason ^ ") -- `masc://library/beta`"));
      check bool "unknown-source document is given no title" false
        (contains text "**Beta Doc**");
      check bool "document without frontmatter named" true
        (contains text "- topic.md (no frontmatter) -- `masc://library/topic`"))
;;

let test_json_index_carries_written_fields_only () =
  with_library ~documents:contract_documents (fun state ->
    let json = json_text state "masc://library.json" in
    let alpha = document_named "alpha" json in
    check (list string) "readable document fields"
      [ "topic"; "title"; "source"; "author"; "created"; "tags"; "uri" ]
      (keys alpha);
    check string "source is the vocabulary word" "research"
      Yojson.Safe.Util.(alpha |> member "source" |> to_string);
    let beta = document_named "beta" json in
    check (list string) "unreadable document fields" [ "topic"; "unreadable"; "uri" ]
      (keys beta);
    check string "unreadable carries the reason" beta_reason
      Yojson.Safe.Util.(beta |> member "unreadable" |> to_string))
;;

let test_json_topic_of_an_unreadable_document () =
  with_library ~documents:contract_documents (fun state ->
    let json = json_text state "masc://library/beta.json" in
    check (list string) "fields" [ "topic"; "unreadable"; "content" ] (keys json);
    check string "content is served" "Beta body"
      Yojson.Safe.Util.(json |> member "content" |> to_string))
;;

let () =
  run
    "library_resource_topic"
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
      , [ test_case "a topic in the listing is served" `Quick test_topic_in_the_library_is_served
        ; test_case
            "blocking resource I/O uses a system thread"
            `Quick
            test_blocking_resource_io_uses_systhread
        ; test_case
            "a topic cannot climb out of docs/library"
            `Quick
            test_topic_cannot_climb_out_of_the_library
        ; test_case
            "library without a separator is not a topic"
            `Quick
            test_prefix_without_separator_is_not_a_topic
        ] )
    ]
;;
