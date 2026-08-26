(* What counts as "this message names a picture". The rule has to survive the
   shapes a path actually arrives in -- a markdown link, backticks, a comma
   after it -- and it has to refuse the shapes that look like paths and are
   not, because every false one is a key that opens nothing. *)

open Alcotest

let paths = Masc_tui_image_ref.paths
let check_paths label expected actual = check (list string) label expected actual

let test_a_bare_path_is_found () =
  check_paths "the path, without the words around it" [ "docs/shot.png" ]
    (paths "see docs/shot.png please")

let test_a_wrapper_does_not_change_the_path () =
  List.iter
    (fun (name, text) ->
      check_paths name [ "docs/a.png" ] (paths text))
    [ ("markdown link", "![the pane](docs/a.png)")
    ; ("backticks", "look at `docs/a.png`")
    ; ("parentheses", "the evidence (docs/a.png) is attached")
    ; ("a comma after it", "docs/a.png, and the log")
    ; ("a full stop after it", "it is docs/a.png.")
    ; ("quoted", "\"docs/a.png\"")
    ]

let test_the_case_of_the_extension_does_not_matter () =
  check_paths "found, and spelled as it was written" [ "~/me/B.PNG" ]
    (paths "`~/me/B.PNG`")

(* A URL has no bytes on this disk. Left alone, the expansion stops at the
   colon and hands back "//host/y.png" -- which reads as an absolute path and
   opens nothing. *)
let test_a_url_is_not_a_path () =
  check_paths "no path" [] (paths "https://example.com/y.png")

let test_a_repeat_is_one_file () =
  check_paths "first mention wins" [ "a.png"; "b.png" ]
    (paths "a.png then b.png then a.png again")

let test_what_is_not_a_path () =
  check_paths "no extension" [] (paths "nothing to look at here");
  check_paths "the extension alone has no file" [] (paths ".png");
  check_paths "the extension has to end the path" []
    (paths "backup.png.bak");
  check_paths "another extension is not offered" []
    (paths "shot.jpg and diagram.svg")

let () =
  run "tui image ref"
    [ ( "paths"
      , [ test_case "a bare path is found" `Quick test_a_bare_path_is_found
        ; test_case "a wrapper does not change the path" `Quick
            test_a_wrapper_does_not_change_the_path
        ; test_case "the case of the extension does not matter" `Quick
            test_the_case_of_the_extension_does_not_matter
        ; test_case "a url is not a path" `Quick test_a_url_is_not_a_path
        ; test_case "a repeat is one file" `Quick test_a_repeat_is_one_file
        ; test_case "what is not a path" `Quick test_what_is_not_a_path
        ] )
    ]
