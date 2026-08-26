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

let test_toml_keys_headers_and_values () =
  check seg "the key, the header and the value each answer"
    [ ("[keeper]", Masc_tui_code_lexer.kind_type)
    ; ("\n", Masc_tui_code_lexer.kind_code)
    ; ("sandbox_profile", Masc_tui_code_lexer.kind_keyword)
    ; (" = ", Masc_tui_code_lexer.kind_code)
    ; ("\"docker\"", Masc_tui_code_lexer.kind_string)
    ]
    (Masc_tui_code_lexer.toml_lexer "[keeper]\nsandbox_profile = \"docker\"")

(* The reason this lexer reads the whole file rather than a row at a time.
   masc's own tool declarations are written this way -- every parameter in
   config/tools/ describes itself inside a triple-quoted block, and a row read
   on its own would paint the prose as keys and operators. *)
let test_a_multiline_string_stays_one_string () =
  let source =
    "description = \"\"\"\nname = not a key\n[not] = a header\n\"\"\"\nafter = 1"
  in
  match Masc_tui_code_lexer.toml_lexer source with
  | (key, key_kind) :: (_, _) :: (body, body_kind) :: rest ->
      check Alcotest.string "the key" "description" key;
      check Alcotest.string "colours as a key" Masc_tui_code_lexer.kind_keyword
        key_kind;
      check Alcotest.string "the block colours as a string"
        Masc_tui_code_lexer.kind_string body_kind;
      Alcotest.(check bool) "and it swallowed the rows inside it" true
        (String.length body > 30);
      Alcotest.(check bool) "the file continues after it" true (rest <> [])
  | segments ->
      Alcotest.failf "expected key, gap, block; got %d segments"
        (List.length segments)

let test_a_hash_comment_runs_to_the_row_end () =
  check seg "the comment stops at the newline"
    [ ("# why this is here", Masc_tui_code_lexer.kind_comment)
    ; ("\n", Masc_tui_code_lexer.kind_code)
    ; ("a", Masc_tui_code_lexer.kind_keyword)
    ; (" = ", Masc_tui_code_lexer.kind_code)
    ; ("1", Masc_tui_code_lexer.kind_number)
    ]
    (Masc_tui_code_lexer.toml_lexer "# why this is here\na = 1")

(* A bare word is a key only when [=] follows it. Without that test every word
   inside a multi-line string would read as one. *)
let test_a_word_without_an_equals_is_not_a_key () =
  (* One segment, not three: runs of the same kind merge, so a row with nothing
     to colour comes back whole. Asserting a split here would be asserting the
     lexer's internals rather than its answer. *)
  check seg "nothing on this row is a key"
    [ ("plain words here", Masc_tui_code_lexer.kind_code) ]
    (Masc_tui_code_lexer.toml_lexer "plain words here")

let test_a_toml_path_picks_the_toml_lexer () =
  check Alcotest.(option string) "by suffix" (Some "toml")
    (Masc_tui_code_lexer.language_of_path "config/tools/masc_keeper_up.toml");
  Alcotest.(check bool) "and the tag resolves" true
    (Option.is_some (Masc_tui_code_lexer.lexer_of_language "toml"))

(* Against a file the repository actually ships rather than a sample written to
   pass. masc_keeper_up.toml is the one that made this lexer whole-file: its
   parameter descriptions are triple-quoted blocks several rows long. *)
let test_a_shipped_declaration_lexes () =
  let path = "config/tools/masc_keeper_up.toml" in
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when Sys.file_exists (Filename.concat root path) -> root
    | _ -> Alcotest.failf "cannot locate %s to read" path
  in
  let text =
    In_channel.with_open_bin (Filename.concat root path) In_channel.input_all
  in
  let segments = Masc_tui_code_lexer.toml_lexer text in
  let cells kind =
    List.fold_left
      (fun total (text, k) ->
         if String.equal k kind then total + String.length text else total)
      0 segments
  in
  Alcotest.(check bool) "the file came back whole" true
    (List.fold_left (fun n (t, _) -> n + String.length t) 0 segments
     = String.length text);
  Alcotest.(check bool) "keys were found" true (cells Masc_tui_code_lexer.kind_keyword > 0);
  Alcotest.(check bool) "headers were found" true (cells Masc_tui_code_lexer.kind_type > 0);
  Alcotest.(check bool) "and the descriptions read as strings" true
    (cells Masc_tui_code_lexer.kind_string > 200)

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
      , [ Alcotest.test_case "keys, headers and values" `Quick
            test_toml_keys_headers_and_values
        ; Alcotest.test_case "a multi-line string stays one string" `Quick
            test_a_multiline_string_stays_one_string
        ; Alcotest.test_case "a hash comment runs to the row end" `Quick
            test_a_hash_comment_runs_to_the_row_end
        ; Alcotest.test_case "a word without an equals is not a key" `Quick
            test_a_word_without_an_equals_is_not_a_key
        ; Alcotest.test_case "a .toml path picks the toml lexer" `Quick
            test_a_toml_path_picks_the_toml_lexer
        ; Alcotest.test_case "a shipped declaration lexes" `Quick
            test_a_shipped_declaration_lexes
        ; Alcotest.test_case "rows split at newlines" `Quick
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
