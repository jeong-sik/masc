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

(* A run of non-ASCII letters is read where no word can be glued onto it:
   right after a [/]. An accent right after an ASCII letter belongs to it. *)
let test_unicode_paths_keep_the_original_bytes () =
  List.iter
    (fun path -> check_paths path [ path ] (paths ("see " ^ path ^ " please")))
    [ "/tmp/화면1.png"
    ; "/tmp/화면/report.png"
    ; "./폴더/스크린샷.png"
    ; "docs/화면.png"
    ; "/tmp/画像はscreenshot.png"
    ; "/tmp/cafe\xcc\x81.png"
    ];
  (* The three inputs #47718 was reported with. *)
  List.iter
    (fun path -> check_paths path [ path ] (paths ("`" ^ path ^ "`")))
    [ "/tmp/화면1.png"; "/tmp/화면.png"; "/tmp/화면/report.png" ];
  List.iter
    (fun (text, path) -> check_paths text [ path ] (paths text))
    [ ("(경로: /tmp/화면.png)", "/tmp/화면.png")
    ; ("확인\xc2\xa0/tmp/화면.png", "/tmp/화면.png")
    ; ("스크린샷은 /tmp/화면.png에 저장했어요", "/tmp/화면.png")
    ]

(* Korean, Japanese, Chinese and Thai prose glues words onto a name with no
   space between them. Where the word ends and the name starts cannot be
   read off the text, so these shapes give no path rather than a joined one
   or a shortened one. *)
let test_a_word_glued_onto_a_name_gives_no_path () =
  List.iter
    (fun text -> check_paths text [] (paths text))
    [ "결과는/tmp/a.png"
    ; "(결과는/tmp/a.png)"
    ; "`폴더/화면.png`"
    ; "see 화면.png"
    ; "画像はscreenshot.pngです"
    ; "(결과는a.png)"
    ; "확장자는.png로 바꿨어요"
    ; "a.txtㆍb.png"
    ; "/tmp/a.svgを/tmp/a.pngに変換しました"
    ; "/tmp/outの/tmp/a.png"
    ]

(* Format characters and combining marks draw nothing of their own. Cutting
   a name at one gives a shorter name; a mark that belongs to the symbol
   before it does not start a name. *)
let test_invisible_and_combining_characters () =
  List.iter
    (fun text -> check_paths text [] (paths text))
    [ "/tmp/\xd8\xa7\xd8\xb3\xda\xa9\xd8\xb1\xdb\x8c\xd9\x86\xe2\x80\x8c\xd8\xb4\xd8\xa7\xd8\xaa.png"
    ; "/tmp/화\xe2\x80\x8e면.png"
    ; "/tmp/screen\xc2\xadshot.png"
    ; "see \xe2\x9a\xa0\xef\xb8\x8f.png"
    ; "a.png\xcc\x81"
    ];
  List.iter
    (fun (text, expected) -> check_paths text expected (paths text))
    [ ("\xe2\x9a\xa0\xef\xb8\x8fa.png", [ "a.png" ])
    ; ("\xe2\x9a\xa0\xef\xb8\x8f/tmp/a.png", [ "/tmp/a.png" ])
    ; ("/tmp/a.png 와 \xe2\x9a\xa0\xef\xb8\x8f.png", [ "/tmp/a.png" ])
    ]

(* Korean puts a particle right after the word, and CJK text closes a
   sentence or a quote with its own punctuation. None of it is the name. *)
let test_what_follows_the_extension_in_korean_text () =
  List.iter
    (fun (text, expected) -> check_paths text expected (paths text))
    [ ("/tmp/a.png를 열어 보세요", [ "/tmp/a.png" ])
    ; ("확인 /tmp/화면.png。다음", [ "/tmp/화면.png" ])
    ; ("「/tmp/a.png」를 열어", [ "/tmp/a.png" ])
    ; ("“/tmp/a.png”.", [ "/tmp/a.png" ])
    ; ("a.png와 b.png를 비교", [ "a.png"; "b.png" ])
    ]

(* Joining two names, or a name and the words before it, offers a file
   nobody named. Each case below gives the right path on main as well, and
   has to keep giving it. *)
let test_neighbours_are_not_joined_into_the_path () =
  List.iter
    (fun (text, expected) -> check_paths text expected (paths text))
    [ ("a.png、b.png", [ "a.png"; "b.png" ])
    ; ("/tmp/a.png，/tmp/b.png", [ "/tmp/a.png"; "/tmp/b.png" ])
    ; ("/tmp/a.txt、/tmp/b.png", [ "/tmp/b.png" ])
    ; ("/tmp/x→/tmp/a.png", [ "/tmp/a.png" ])
    ; ("경로：a.png", [ "a.png" ])
    ; ("(a.txt,b.png)", [ "b.png" ])
    ; ("(foo.txt,/tmp/a.png)", [ "/tmp/a.png" ])
    ; ("(see docs/a.png)", [ "docs/a.png" ])
    ; ("`open /tmp/a.png`", [ "/tmp/a.png" ])
    ; ("`/usr/bin/open /tmp/a.png`", [ "/tmp/a.png" ])
    ; ("`/tmp/notes.txt /tmp/a.png`", [ "/tmp/a.png" ])
    ; ("`--output=/tmp/a.png`", [ "/tmp/a.png" ])
    ; ("\"saved to /tmp/a.png\"", [ "/tmp/a.png" ])
    ];
  (* With no separator between them, the second name could start anywhere
     inside the first. *)
  check_paths "a name glued to the previous one is declined" [ "a.png" ]
    (paths "a.png와b.png")

let test_urls_do_not_contribute_local_suffixes () =
  List.iter
    (fun text -> check_paths text [] (paths text))
    [ "https://example.com/화면1.png"
    ; "https://example.com/a(1)/file.png"
    ; "https://example.com?file=other.png"
    ; "https://example.com/?path=/tmp/사진.png"
    ; "https://example.com/#/tmp/사진.png"
    ; "https://[::1]/사진.png"
    ; "(file:/tmp/a.png)"
    ];
  check_paths "a later local path remains available" [ "/tmp/다음.png" ]
    (paths "https://example.com/?path=/tmp/사진.png /tmp/다음.png")

let test_invalid_and_control_bytes_do_not_produce_suffixes () =
  check_paths "invalid UTF-8 rejects the message's candidates" []
    (paths "/tmp/\xff/foo.png");
  check_paths "a control inside a bare name is not a separator" []
    (paths "/tmp/pre\x1bpost.png");
  check_paths "a control inside a quoted name is not a separator" []
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
        ; test_case "a word glued onto a name gives no path" `Quick
            test_a_word_glued_onto_a_name_gives_no_path
        ; test_case "invisible and combining characters" `Quick
            test_invisible_and_combining_characters
        ; test_case "what follows the extension in Korean text" `Quick
            test_what_follows_the_extension_in_korean_text
        ; test_case "neighbours are not joined into the path" `Quick
            test_neighbours_are_not_joined_into_the_path
        ; test_case "URLs do not contribute local suffixes" `Quick
            test_urls_do_not_contribute_local_suffixes
        ; test_case "invalid and control bytes do not produce suffixes" `Quick
            test_invalid_and_control_bytes_do_not_produce_suffixes
        ] )
    ]
