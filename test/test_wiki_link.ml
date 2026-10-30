(* Wiki_link: the link parser is total and names the shapes it does not
   interpret (RFC-wiki-lint-and-page-contracts §5). *)

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

let () =
  run
    "wiki_link"
    [ ( "classify", [ test_case "table" `Quick test_classify_table ] )
    ; ( "extract"
      , [ test_case "plain links and their lines" `Quick test_plain_links_and_lines
        ; test_case "unsupported shapes are values" `Quick test_unsupported_shapes_are_values
        ; test_case "code and images are skipped" `Quick test_code_and_images_are_skipped
        ; test_case "odd input does not raise" `Quick
            test_unmatched_and_odd_input_does_not_raise
        ; test_case "title and angle target" `Quick test_title_and_angle_target
        ] )
    ]
;;
