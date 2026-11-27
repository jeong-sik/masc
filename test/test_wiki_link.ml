(* Wiki_link: the link parser is total and names the shapes it does not
   interpret. *)

open Alcotest
module L = Masc.Wiki_link

let target_to_string = function
  | L.Page name -> "page:" ^ name
  | L.Own_file name -> "own:" ^ name
  | L.External url -> "external:" ^ url
  | L.Invalid_name name -> "invalid:" ^ name
  | L.Unsupported shape -> "unsupported:" ^ shape
;;

let targets body = List.map (fun (link : L.link) -> target_to_string link.target) (L.extract body)

let check_targets label body expected = check (list string) label expected (targets body)

let test_classify_table () =
  List.iter
    (fun (raw, expected) ->
       check string raw expected (target_to_string (L.classify raw)))
    [ "alpha.md", "page:alpha"
    ; "a-b-2.md", "page:a-b-2"
    ; "Foo.md", "invalid:Foo.md"
    ; "-edge.md", "invalid:-edge.md"
    ; "with space.md", "invalid:with space.md"
    ; "index.md", "own:index.md"
    ; "log.md", "own:log.md"
    ; "alpha.md#section", "unsupported:anchor"
    ; "#section", "unsupported:anchor"
    ; "../x.md", "unsupported:path"
    ; "a/b.md", "unsupported:path"
    ; "https://example.org/a", "external:https://example.org/a"
    ; "http://example.org", "external:http://example.org"
    ; "mailto:a@b.c", "unsupported:scheme"
    ; "masc://wiki/alpha", "unsupported:scheme"
    ; "notes.txt", "unsupported:not_markdown"
    ; "", "unsupported:not_markdown"
    ]
;;

let test_plain_links_and_lines () =
  let body = "# Title\n\nSee [alpha](alpha.md) and\n[beta](beta.md).\n" in
  let links = L.extract body in
  check (list string) "targets" [ "page:alpha"; "page:beta" ]
    (List.map (fun (l : L.link) -> target_to_string l.target) links);
  check (list int) "lines" [ 3; 4 ] (List.map (fun (l : L.link) -> l.line) links);
  check (list string) "labels" [ "alpha"; "beta" ]
    (List.map (fun (l : L.link) -> l.text) links)
;;

let test_unsupported_shapes_are_values () =
  check_targets "wikilink, anchor, relative path"
    "[[Some Page]] then [x](a.md#top) and [y](../z.md)"
    [ "unsupported:wikilink"; "unsupported:anchor"; "unsupported:path" ];
  check (list string) "wikilink keeps its name" [ "Some Page" ]
    (List.map (fun (l : L.link) -> l.text) (L.extract "[[Some Page]]"))
;;

let test_code_and_images_are_skipped () =
  check_targets "fenced block" "```\n[a](a.md)\n```\n[b](b.md)\n" [ "page:b" ];
  check_targets "tilde fence" "~~~ md\n[a](a.md)\n~~~\n[b](b.md)\n" [ "page:b" ];
  check_targets "longer closing fence" "```\n[a](a.md)\n`````\n[b](b.md)\n" [ "page:b" ];
  check_targets "a shorter run does not close" "````\n[a](a.md)\n```\n[b](b.md)\n````\n[c](c.md)\n"
    [ "page:c" ];
  check_targets "inline code" "`[a](a.md)` and [b](b.md)" [ "page:b" ];
  check_targets "double-backtick span" "``a ` [x](x.md)`` [b](b.md)" [ "page:b" ];
  check_targets "image" "![alt](pic.png) [b](b.md)" [ "page:b" ];
  check_targets "image whose target is a page" "![alt](a.md) [b](b.md)" [ "page:b" ]
;;

let test_unmatched_and_odd_input_does_not_raise () =
  List.iter
    (fun body -> ignore (L.extract body : L.link list))
    [ ""
    ; "["
    ; "[]("
    ; "[a]("
    ; "[a](b"
    ; "[[a"
    ; "![a]("
    ; "`"
    ; "``` unterminated\n[a](a.md)"
    ; "[a [b]](c.md)"
    ; "\r\n[a](a.md)\r\n"
    ];
  check_targets "nested brackets in a label" "[a [b]](c.md)" [ "page:c" ];
  check_targets "unterminated fence swallows the rest" "``` x\n[a](a.md)" [];
  check_targets "carriage returns" "[a](a.md)\r\n[b](b.md)\r\n" [ "page:a"; "page:b" ]
;;

let test_title_and_angle_target () =
  check_targets "a title after the target" "[a](a.md \"A title\")" [ "page:a" ];
  check_targets "angle brackets" "[a](<a.md>)" [ "page:a" ];
  check (list string) "raw drops the title" [ "a.md" ]
    (List.map (fun (l : L.link) -> l.raw) (L.extract "[a](a.md \"A title\")"))
;;

let embed_target_to_string = function
  | L.Media_embed sha -> "media:" ^ sha
  | L.Wiki_embed slug -> "wiki:" ^ slug
  | L.Artifact_embed id -> "artifact:" ^ id
  | L.Invalid_embed { kind; raw } ->
    "invalid:" ^ L.embed_kind_to_string kind ^ ":" ^ raw
  | L.Unsupported_embed { scheme; raw } -> "unsupported:" ^ scheme ^ ":" ^ raw
;;

let sample_sha_a = String.make 64 'a'
let sample_sha_b = String.make 64 'b'
let sample_artifact = "artifact-0123456789abcdef0123456789abcdef"

let test_obsidian_embeds_skipped_by_link_extract () =
  check_targets "obsidian embeds do not emit links"
    (Printf.sprintf
       "![[wiki:alpha]] ![[media:%s|see [inner](inner.md)]] ![[artifact:%s]] [ok](ok.md)"
       sample_sha_a
       sample_artifact)
    [ "page:ok" ]
;;

let test_classify_obsidian_embed_table () =
  let upper_sha = String.make 64 'A' in
  List.iter
    (fun (raw, expected) ->
       check string raw expected (embed_target_to_string (L.classify_obsidian_embed raw)))
    [ "media:" ^ sample_sha_a, "media:" ^ sample_sha_a
    ; "media:short", "invalid:media:short"
    ; "media:" ^ upper_sha, "invalid:media:" ^ upper_sha
    ; "media:", "invalid:media:"
    ; "wiki:alpha-1", "wiki:alpha-1"
    ; "alpha-1", "wiki:alpha-1"
    ; "wiki:Bad_Name", "invalid:wiki:Bad_Name"
    ; "wiki:index", "invalid:wiki:index"
    ; "", "invalid:wiki:"
    ; "artifact:" ^ sample_artifact, "artifact:" ^ sample_artifact
    ; "artifact:not-an-id", "invalid:artifact:not-an-id"
    ; "file:diagram.png", "unsupported:file:diagram.png"
    ; ":leading-colon", "unsupported::leading-colon"
    ]
;;

let test_extract_embeds_and_media_refs () =
  let body =
    String.concat
      "\n"
      [ Printf.sprintf "![[media:%s|Hero diagram]]" sample_sha_b
      ; "![[wiki:design-notes|Design Notes]] and ![[overview]]"
      ; Printf.sprintf "![[artifact:%s|Q4 Report]]" sample_artifact
      ; Printf.sprintf "![Chart](/api/v1/media/%s \"title\")" sample_sha_a
      ; Printf.sprintf "![Dup](</api/v1/media/%s>)" sample_sha_b
      ; "![Bad](/api/v1/media/not-a-sha)"
      ; "![[other:thing|lbl]]"
      ]
  in
  let embeds = L.extract_embeds body in
  check
    (list string)
    "embed targets in reading order"
    [ "media:" ^ sample_sha_b
    ; "wiki:design-notes"
    ; "wiki:overview"
    ; "artifact:" ^ sample_artifact
    ; "media:" ^ sample_sha_a
    ; "media:" ^ sample_sha_b
    ; "invalid:media:not-a-sha"
    ; "unsupported:other:thing"
    ]
    (List.map (fun (e : L.embed) -> embed_target_to_string e.target) embeds);
  check
    (list (option string))
    "labels"
    [ Some "Hero diagram"
    ; Some "Design Notes"
    ; None
    ; Some "Q4 Report"
    ; Some "Chart"
    ; Some "Dup"
    ; Some "Bad"
    ; Some "lbl"
    ]
    (List.map (fun (e : L.embed) -> e.label) embeds);
  check
    (list string)
    "syntaxes"
    [ "obsidian"
    ; "obsidian"
    ; "obsidian"
    ; "obsidian"
    ; "markdown_media"
    ; "markdown_media"
    ; "markdown_media"
    ; "obsidian"
    ]
    (List.map (fun (e : L.embed) -> L.embed_syntax_to_string e.syntax) embeds);
  check
    (list int)
    "lines"
    [ 1; 2; 2; 3; 4; 5; 6; 7 ]
    (List.map (fun (e : L.embed) -> e.line) embeds);
  check
    (list string)
    "media_refs sorted and deduplicated"
    [ sample_sha_a; sample_sha_b ]
    (L.media_refs_of_embeds embeds)
;;

let test_embed_code_and_non_media_images_skipped () =
  let body =
    String.concat
      "\n"
      [ "```md"
      ; Printf.sprintf "![[media:%s]]" sample_sha_a
      ; Printf.sprintf "![x](/api/v1/media/%s)" sample_sha_a
      ; "```"
      ; Printf.sprintf "`![[media:%s]]` `![x](/api/v1/media/%s)`" sample_sha_a sample_sha_b
      ; "![ext](https://example.org/api/v1/media/" ^ sample_sha_a ^ ")"
      ; "![local](diagram.png)"
      ; Printf.sprintf "![real](/api/v1/media/%s)" sample_sha_b
      ]
  in
  check
    (list string)
    "only real unquoted media embed survives"
    [ "media:" ^ sample_sha_b ]
    (List.map (fun (e : L.embed) -> embed_target_to_string e.target) (L.extract_embeds body))
;;

let test_embed_odd_inputs_do_not_raise () =
  List.iter
    (fun body -> ignore (L.extract_embeds body : L.embed list))
    [ ""; "![["; "![[]]"; "![[a|]]"; "![[a|b|c]]"; "![alt](/api/v1/media/"; "![](/api/v1/media/)" ];
  check
    (list string)
    "empty obsidian embed is invalid wiki"
    [ "invalid:wiki:" ]
    (List.map (fun (e : L.embed) -> embed_target_to_string e.target) (L.extract_embeds "![[]]"));
  check
    (list string)
    "empty media path is invalid media"
    [ "invalid:media:" ]
    (List.map
       (fun (e : L.embed) -> embed_target_to_string e.target)
       (L.extract_embeds "![](/api/v1/media/)"))
;;

let () =
  run
    "wiki_link"
    [ ( "classify", [ test_case "table" `Quick test_classify_table ] )
    ; ( "extract"
      , [ test_case "plain links and their lines" `Quick test_plain_links_and_lines
        ; test_case "unsupported shapes are values" `Quick test_unsupported_shapes_are_values
        ; test_case "code and images are skipped" `Quick test_code_and_images_are_skipped
        ; test_case "obsidian embeds are skipped by link extract" `Quick
            test_obsidian_embeds_skipped_by_link_extract
        ; test_case "odd input does not raise" `Quick
            test_unmatched_and_odd_input_does_not_raise
        ; test_case "title and angle target" `Quick test_title_and_angle_target
        ] )
    ; ( "embeds"
      , [ test_case "classify obsidian embed table" `Quick test_classify_obsidian_embed_table
        ; test_case "extract embeds and media_refs" `Quick test_extract_embeds_and_media_refs
        ; test_case "code blocks and non-media images skipped" `Quick
            test_embed_code_and_non_media_images_skipped
        ; test_case "odd embed input does not raise" `Quick test_embed_odd_inputs_do_not_raise
        ] )
    ]
;;
