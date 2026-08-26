(* The lexers' contracts, asserted at their new home. These are the shapes
   the fence rendering has relied on; the Code surface inherits them. *)

let check = Alcotest.check
let seg = Alcotest.(list (pair string string))

let test_reserved_words_colour_as_keywords () =
  check seg "let is a keyword, x is not"
    [ ("let", Masc_tui_code_lexer.kind_keyword)
    ; (" x = ", Masc_tui_code_lexer.kind_code)
    ; ("1", Masc_tui_code_lexer.kind_number)
    ]
    (Masc_tui_code_lexer.ocaml_lexer "let x = 1")

let test_a_nested_comment_ends_at_its_real_close () =
  check seg "the whole nest is one comment"
    [ ("(* a (* b *) c *)", Masc_tui_code_lexer.kind_comment)
    ; (" x", Masc_tui_code_lexer.kind_code)
    ]
    (Masc_tui_code_lexer.ocaml_lexer "(* a (* b *) c *) x")

let test_capitalised_words_read_as_types () =
  match Masc_tui_code_lexer.ocaml_lexer "Some 1" with
  | (word, kind) :: _ ->
      check Alcotest.string "the constructor" "Some" word;
      check Alcotest.string "colours as a type" Masc_tui_code_lexer.kind_type
        kind
  | [] -> Alcotest.fail "the lexer answered nothing"

let test_rows_split_at_newlines () =
  let rows =
    Masc_tui_code_lexer.rows_of_source ~language:(Some "ocaml")
      "let a = 1\nlet b = 2"
  in
  Alcotest.(check int) "two rows" 2 (List.length rows)

let test_an_unlexed_language_stays_one_plain_span () =
  let rows =
    Masc_tui_code_lexer.rows_of_source ~language:(Some "brainfuck") "+[->+<]"
  in
  check seg "one row, one plain segment"
    [ ("+[->+<]", Masc_tui_code_lexer.kind_code) ]
    (List.concat rows);
  let untagged = Masc_tui_code_lexer.rows_of_source ~language:None "x" in
  check seg "no language, same fallback"
    [ ("x", Masc_tui_code_lexer.kind_code) ]
    (List.concat untagged)

let test_the_extension_table_names_only_lexed_languages () =
  let lang = Masc_tui_code_lexer.language_of_path in
  Alcotest.(check (option string)) ".ml" (Some "ocaml") (lang "lib/a.ml");
  Alcotest.(check (option string)) ".mli" (Some "ocaml") (lang "lib/a.mli");
  Alcotest.(check (option string)) ".sh" (Some "bash") (lang "run.sh");
  Alcotest.(check (option string)) ".json" (Some "json") (lang "conf.json");
  Alcotest.(check (option string)) ".ts is c_like" (Some "c_like")
    (lang "app.ts");
  Alcotest.(check (option string)) ".go is c_like" (Some "c_like")
    (lang "main.go");
  Alcotest.(check (option string)) ".rs is c_like" (Some "c_like")
    (lang "lib.rs");
  Alcotest.(check (option string)) ".py is python" (Some "python")
    (lang "tool.py");
  Alcotest.(check (option string)) "unlexed .rb stays None" None (lang "app.rb");
  Alcotest.(check (option string)) "no extension" None (lang "Makefile")

let test_c_like_reads_keyword_number_line_comment () =
  check seg "const keyword, number, // comment"
    [ ("const", Masc_tui_code_lexer.kind_keyword)
    ; (" n = ", Masc_tui_code_lexer.kind_code)
    ; ("42", Masc_tui_code_lexer.kind_number)
    ; (" ", Masc_tui_code_lexer.kind_code)
    ; ("// c", Masc_tui_code_lexer.kind_comment)
    ]
    (Masc_tui_code_lexer.c_like_lexer "const n = 42 // c")

let test_c_like_reads_block_comment_and_string () =
  check seg "string then /* block */ comment"
    [ ("a = ", Masc_tui_code_lexer.kind_code)
    ; ("\"hi\"", Masc_tui_code_lexer.kind_string)
    ; (" ", Masc_tui_code_lexer.kind_code)
    ; ("/* b */", Masc_tui_code_lexer.kind_comment)
    ]
    (Masc_tui_code_lexer.c_like_lexer "a = \"hi\" /* b */")

let test_python_reads_keyword_and_hash_comment () =
  check seg "def keyword, # comment"
    [ ("def", Masc_tui_code_lexer.kind_keyword)
    ; (" f(): ", Masc_tui_code_lexer.kind_code)
    ; ("# c", Masc_tui_code_lexer.kind_comment)
    ]
    (Masc_tui_code_lexer.python_lexer "def f(): # c")

let test_python_reads_triple_quoted_string () =
  check seg "a triple-quoted docstring is one string"
    [ ("x = ", Masc_tui_code_lexer.kind_code)
    ; ("\"\"\"doc\"\"\"", Masc_tui_code_lexer.kind_string)
    ]
    (Masc_tui_code_lexer.python_lexer "x = \"\"\"doc\"\"\"")

let () =
  Alcotest.run "masc_tui_code_lexer"
    [ ( "ocaml"
      , [ Alcotest.test_case "reserved words colour as keywords" `Quick
            test_reserved_words_colour_as_keywords
        ; Alcotest.test_case "a nested comment ends at its real close" `Quick
            test_a_nested_comment_ends_at_its_real_close
        ; Alcotest.test_case "capitalised words read as types" `Quick
            test_capitalised_words_read_as_types
        ] )
    ; ( "rows"
      , [ Alcotest.test_case "rows split at newlines" `Quick
            test_rows_split_at_newlines
        ; Alcotest.test_case "an unlexed language stays one plain span" `Quick
            test_an_unlexed_language_stays_one_plain_span
        ] )
    ; ( "c_like"
      , [ Alcotest.test_case "keyword, number and line comment" `Quick
            test_c_like_reads_keyword_number_line_comment
        ; Alcotest.test_case "block comment and string" `Quick
            test_c_like_reads_block_comment_and_string
        ] )
    ; ( "python"
      , [ Alcotest.test_case "keyword and hash comment" `Quick
            test_python_reads_keyword_and_hash_comment
        ; Alcotest.test_case "triple-quoted string" `Quick
            test_python_reads_triple_quoted_string
        ] )
    ; ( "paths"
      , [ Alcotest.test_case "the extension table names only lexed languages"
            `Quick test_the_extension_table_names_only_lexed_languages
        ] )
    ]
