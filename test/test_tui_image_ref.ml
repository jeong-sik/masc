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
  check_paths "found, and spelled as it was written" [ "~/ws/B.PNG" ]
    (paths "`~/ws/B.PNG`")

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

let test_unicode_paths_keep_the_original_bytes () =
  List.iter
    (fun path -> check_paths path [ path ] (paths ("see " ^ path ^ " please")))
    [ "/tmp/화면1.png"
    ; "/tmp/화면/report.png"
    ; "./폴더/스크린샷.png"
    ; "화면.png"
    ; "cafe\xcc\x81.png"
    ; "👩‍💻.png"
    ];
  (* The three inputs #47718 was reported with. *)
  List.iter
    (fun path -> check_paths path [ path ] (paths ("`" ^ path ^ "`")))
    [ "/tmp/화면1.png"; "/tmp/화면.png"; "/tmp/화면/report.png" ];
  check_paths "ambiguous bare Unicode first directory is declined" []
    (paths "결과는/tmp/a.png");
  check_paths "an explicitly delimited Unicode directory is preserved"
    [ "폴더/화면.png" ] (paths "`폴더/화면.png`")

let test_enclosed_paths_and_unicode_punctuation () =
  List.iter
    (fun (text, path) -> check_paths text [ path ] (paths text))
    [ ("`/tmp/my photo.png`", "/tmp/my photo.png")
    ; ("![화면](/tmp/한글/my (photo).png)", "/tmp/한글/my (photo).png")
    ; ("“/tmp/my 화면.png”", "/tmp/my 화면.png")
    ; ("`/tmp/중간。dir/a.png`", "/tmp/중간。dir/a.png")
    ; ("확인 /tmp/화면.png。", "/tmp/화면.png")
    ; ("확인\xc2\xa0/tmp/화면.png", "/tmp/화면.png")
    ];
  check_paths "Unicode text after the extension is not a PNG suffix" []
    (paths "/tmp/화면.png다음");
  check_paths "a wrapper around an earlier path does not join two paths"
    [ "/tmp/a.png"; "/tmp/b.png" ] (paths "`/tmp/a.png and /tmp/b.png`");
  check_paths "a wrapper around a list does not join its items"
    [ "a.png"; "b.png" ] (paths "(a.png,b.png)");
  check_paths "a punctuation continuation remains ambiguous" []
    (paths "/tmp/화면.png。다음")

(* A wrapper holds whatever the writer put in it: a command, a label, a
   sentence. Only a wrapper that opens on a path root holds one path with
   spaces in it; otherwise the words before the path stay words. *)
let test_words_inside_a_wrapper_are_not_the_path () =
  List.iter
    (fun (text, path) -> check_paths text [ path ] (paths text))
    [ ("(see docs/a.png)", "docs/a.png")
    ; ("`open /tmp/a.png`", "/tmp/a.png")
    ; ("(경로: /tmp/화면.png)", "/tmp/화면.png")
    ; ("\"saved to /tmp/a.png\"", "/tmp/a.png")
    ; ( "`/Users/me/Desktop/Screenshot 2026-11-03 at 02.14.45.png`"
      , "/Users/me/Desktop/Screenshot 2026-11-03 at 02.14.45.png" )
    ]

let test_urls_do_not_contribute_local_suffixes () =
  List.iter
    (fun text -> check_paths text [] (paths text))
    [ "https://example.com/화면1.png"
    ; "https://example.com/a(1)/file.png"
    ; "https://example.com?file=other.png"
    ; "https://example.com/?path=/tmp/사진.png"
    ; "https://example.com/#/tmp/사진.png"
    ; "https://[::1]/사진.png"
    ];
  check_paths "a later local path remains available" [ "/tmp/다음.png" ]
    (paths "https://example.com/?path=/tmp/사진.png /tmp/다음.png")

let test_invalid_and_control_bytes_do_not_produce_suffixes () =
  check_paths "invalid UTF-8 rejects the message's candidates" []
    (paths "/tmp/\xff/foo.png");
  check_paths "control inside a bare candidate is not a separator" []
    (paths "/tmp/pre\x1bpost.png");
  check_paths "control inside a quoted candidate is not a filename" []
    (paths "`/tmp/pre\x1bpost.png`")

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
        ; test_case "Unicode paths keep their original bytes" `Quick
            test_unicode_paths_keep_the_original_bytes
        ; test_case "enclosed paths and Unicode punctuation" `Quick
            test_enclosed_paths_and_unicode_punctuation
        ; test_case "words inside a wrapper are not the path" `Quick
            test_words_inside_a_wrapper_are_not_the_path
        ; test_case "URLs do not contribute local suffixes" `Quick
            test_urls_do_not_contribute_local_suffixes
        ; test_case "invalid and control bytes do not produce suffixes" `Quick
            test_invalid_and_control_bytes_do_not_produce_suffixes
        ] )
    ]
