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
  Alcotest.(check (option string)) ".yaml" (Some "yaml") (lang "ci.yaml");
  Alcotest.(check (option string)) ".yml" (Some "yaml") (lang "ci.yml");
  Alcotest.(check (option string)) ".toml" (Some "toml")
    (lang "repositories.toml");
  Alcotest.(check (option string)) ".sql" (Some "sql") (lang "schema.sql");
  (* The diff lexer was here before either of these answered: a patch opened
     as a file read as prose while the same text inside a fence read as a
     diff. *)
  Alcotest.(check (option string)) ".patch is diff" (Some "diff")
    (lang "fix.patch");
  Alcotest.(check (option string)) ".diff is diff" (Some "diff")
    (lang "fix.diff");
  Alcotest.(check (option string)) "unlexed .rb stays None" None (lang "app.rb");
  Alcotest.(check (option string)) "no extension" None (lang "Makefile")

let spans language text =
  Masc_tui_code_lexer.rows_of_source ~language:(Some language) text
  |> List.concat
  |> List.filter (fun (piece, _) -> piece <> "")

let test_yaml_reads_a_key_a_value_and_a_comment () =
  check seg "the key, the rest, the comment"
    [ ("name", Masc_tui_code_lexer.kind_type)
    ; (": masc ", Masc_tui_code_lexer.kind_code)
    ; ("# why", Masc_tui_code_lexer.kind_comment)
    ]
    (spans "yaml" "name: masc # why")

(* The line's first word is a key only where a colon closes it. Without this
   every bare list item and every wrapped line would take the key colour, and
   the column would stop meaning anything. *)
let test_a_yaml_line_with_no_colon_holds_no_key () =
  check seg "a list item is a value"
    [ ("- just an item", Masc_tui_code_lexer.kind_code) ]
    (spans "yaml" "- just an item")

let test_a_yaml_key_survives_its_list_marker () =
  check seg "the word after \"- \" is still a key"
    [ ("- ", Masc_tui_code_lexer.kind_code)
    ; ("name", Masc_tui_code_lexer.kind_type)
    ; (": masc", Masc_tui_code_lexer.kind_code)
    ]
    (spans "yaml" "- name: masc")

let test_toml_reads_a_key_a_string_and_a_comment () =
  check seg "the key, the delimiter, the string, the comment"
    [ ("name", Masc_tui_code_lexer.kind_type)
    ; (" = ", Masc_tui_code_lexer.kind_code)
    ; ("\"masc\"", Masc_tui_code_lexer.kind_string)
    ; (" ", Masc_tui_code_lexer.kind_code)
    ; ("# why", Masc_tui_code_lexer.kind_comment)
    ]
    (spans "toml" "name = \"masc\" # why")

let test_a_toml_table_header_is_taken_whole () =
  match Masc_tui_code_lexer.rows_of_source ~language:(Some "toml")
          "[[repository]]\nname = 1" with
  | header :: _ ->
      check seg "the brackets belong to the name"
        [ ("[[repository]]", Masc_tui_code_lexer.kind_keyword) ]
        (List.filter (fun (piece, _) -> piece <> "") header)
  | [] -> Alcotest.fail "the lexer answered no rows"

let test_sql_reads_a_keyword_however_it_is_spelled () =
  let kinds text = List.map snd (spans "sql" text) in
  check Alcotest.(list string) "shouting does not change the shape"
    (kinds "select a from t")
    (kinds "SELECT a FROM t");
  match spans "sql" "SELECT 1" with
  | (word, kind) :: _ ->
      check Alcotest.string "the verb" "SELECT" word;
      check Alcotest.string "colours as a keyword"
        Masc_tui_code_lexer.kind_keyword kind
  | [] -> Alcotest.fail "the lexer answered nothing"

let test_sql_double_quotes_name_rather_than_hold_text () =
  check seg "a quoted name is an identifier, not a value"
    [ ("select", Masc_tui_code_lexer.kind_keyword)
    ; (" ", Masc_tui_code_lexer.kind_code)
    ; ("\"user id\"", Masc_tui_code_lexer.kind_type)
    ]
    (spans "sql" "select \"user id\"")

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
    ; ( "config"
      , [ Alcotest.test_case "yaml reads a key, a value and a comment" `Quick
            test_yaml_reads_a_key_a_value_and_a_comment
        ; Alcotest.test_case "a yaml line with no colon holds no key" `Quick
            test_a_yaml_line_with_no_colon_holds_no_key
        ; Alcotest.test_case "a yaml key survives its list marker" `Quick
            test_a_yaml_key_survives_its_list_marker
        ; Alcotest.test_case "toml reads a key, a string and a comment" `Quick
            test_toml_reads_a_key_a_string_and_a_comment
        ; Alcotest.test_case "a toml table header is taken whole" `Quick
            test_a_toml_table_header_is_taken_whole
        ] )
    ; ( "sql"
      , [ Alcotest.test_case "a keyword however it is spelled" `Quick
            test_sql_reads_a_keyword_however_it_is_spelled
        ; Alcotest.test_case "double quotes name rather than hold text" `Quick
            test_sql_double_quotes_name_rather_than_hold_text
        ] )
    ; ( "paths"
      , [ Alcotest.test_case "the extension table names only lexed languages"
            `Quick test_the_extension_table_names_only_lexed_languages
        ] )
    ]
