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

let test_assignment_rows_ignore_strings_and_comments () =
  let rows =
    Masc_tui_code_lexer.rows_of_source ~language:(Some "toml")
      "# example = false\nname = \"a=b\"\n[models.alpha]\nplain text"
  in
  Alcotest.(check (list bool))
    "only the real assignment is navigable"
    [ false; true; false; false ]
    (List.map Masc_tui_code_lexer.row_has_assignment rows)

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

(* The Librarian's commit. Two questions on one line -- did this fact arrive
   or leave, and what kind of thing is it -- so two channels: the sign keeps
   the diff colours it always had, and the category takes one of its own. *)
let test_memory_reads_the_sign_and_the_category () =
  check seg "arrived, and a change to the code"
    [ ("+ ", Masc_tui_code_lexer.kind_diff_added)
    ; ("[", Masc_tui_code_lexer.kind_comment)
    ; ("code_change", Masc_tui_code_lexer.kind_type)
    ; ("]", Masc_tui_code_lexer.kind_comment)
    ; (" api changed", Masc_tui_code_lexer.kind_code)
    ]
    (spans "memory" "+ [code_change] api changed");
  check seg "left, and a plain fact"
    [ ("- ", Masc_tui_code_lexer.kind_diff_removed)
    ; ("[", Masc_tui_code_lexer.kind_comment)
    (* [fact] is the default kind and the most common one. Colouring the
       majority says nothing about it. *)
    ; ("fact", Masc_tui_code_lexer.kind_code)
    ; ("]", Masc_tui_code_lexer.kind_comment)
    ; (" the old thing", Masc_tui_code_lexer.kind_code)
    ]
    (spans "memory" "- [fact] the old thing")

(* Eight categories and five colours: grouped by what a reader does about it,
   because eight hues is a legend to memorise. What matters is that the groups
   stay apart. *)
let test_the_categories_group_rather_than_collide () =
  let kind_of category =
    match spans "memory" (Printf.sprintf "+ [%s] claim" category) with
    | _ :: _ :: (_, kind) :: _ -> kind
    | _ -> Alcotest.fail ("no category span for " ^ category)
  in
  let same a b = String.equal (kind_of a) (kind_of b) in
  Alcotest.(check bool) "a lesson and an approach read alike" true
    (same "lesson" "validated_approach");
  Alcotest.(check bool) "a preference and a goal read alike" true
    (same "preference" "goal");
  Alcotest.(check bool) "a code change is not a lesson" false
    (same "code_change" "lesson");
  Alcotest.(check bool) "a blocker is not a preference" false
    (same "blocker" "preference");
  (* A category this has not been taught reads as a fact rather than
     borrowing a colour that would say something about it. *)
  Alcotest.(check bool) "an unknown category reads as a fact" true
    (same "some_new_category" "fact")

let test_a_drop_line_is_the_quietest_row () =
  check seg "the whole line recedes"
    [ ("drop sha256:0cfb \xe2\x80\x94 the api changed",
       Masc_tui_code_lexer.kind_comment) ]
    (spans "memory" "drop sha256:0cfb \xe2\x80\x94 the api changed")

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

(* A digit inside a scalar belongs to the scalar. [actions/checkout@v4] is a
   name; colouring its [4] picks one character out of a word and says it means
   something on its own. The same boundary holds the three literal words. *)
let test_a_digit_inside_a_scalar_is_not_a_value () =
  check seg "the version is part of the name"
    [ ("uses", Masc_tui_code_lexer.kind_type)
    ; (": actions/checkout@v4", Masc_tui_code_lexer.kind_code)
    ]
    (spans "yaml" "uses: actions/checkout@v4");
  check seg "a value standing on its own is still a value"
    [ ("port", Masc_tui_code_lexer.kind_type)
    ; (": ", Masc_tui_code_lexer.kind_code)
    ; ("8935", Masc_tui_code_lexer.kind_number)
    ]
    (spans "yaml" "port: 8935")

let test_a_literal_inside_a_scalar_is_not_a_literal () =
  check seg "a word that contains one is not one"
    (* One run: the delimiter and the word are both plain, and adjacent
       characters of one kind are one segment. *)
    [ ("mode", Masc_tui_code_lexer.kind_type)
    ; (" = true-ish", Masc_tui_code_lexer.kind_code)
    ]
    (spans "toml" "mode = true-ish");
  check seg "and one standing on its own still is"
    [ ("mode", Masc_tui_code_lexer.kind_type)
    ; (" = ", Masc_tui_code_lexer.kind_code)
    ; ("true", Masc_tui_code_lexer.kind_number)
    ]
    (spans "toml" "mode = true")

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

(* Both lexer tests below run under this: a hang has to end as a failure
   with a name, not as a job that runs until CI stops it. OCaml 5 polls for
   signals inside loops, so the handler reaches even a branch that is making
   no progress. *)
let under_alarm seconds report body =
  let previous =
    Sys.signal Sys.sigalrm
      (Sys.Signal_handle (fun _ -> Alcotest.failf "did not finish: %s" (report ())))
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Unix.alarm 0);
      Sys.set_signal Sys.sigalrm previous)
    (fun () ->
      ignore (Unix.alarm seconds);
      body ())

(* A negative number used to stop the json lexer where it stood: the branch
   admits a leading sign, the digit scan rejects one, and a scan that matches
   nothing returns the index it was given. Opening a .json file holding one
   froze the TUI. The first case answers whether the lexer finishes at all;
   the rest keep the sign from taking more than its own number. *)
let test_json_reads_a_negative_number () =
  under_alarm 10 (fun () -> "json on a negative number") @@ fun () ->
  check seg "the sign belongs to the number"
    [ ("{", Masc_tui_code_lexer.kind_code)
    ; ("\"a\"", Masc_tui_code_lexer.kind_type)
    ; (": ", Masc_tui_code_lexer.kind_code)
    ; ("-1", Masc_tui_code_lexer.kind_number)
    ; ("}", Masc_tui_code_lexer.kind_code)
    ]
    (spans "json" {|{"a": -1}|});
  check seg "a negative decimal in a list"
    [ ("[", Masc_tui_code_lexer.kind_code)
    ; ("-2.5", Masc_tui_code_lexer.kind_number)
    ; (", ", Masc_tui_code_lexer.kind_code)
    ; ("3", Masc_tui_code_lexer.kind_number)
    ; ("]", Masc_tui_code_lexer.kind_code)
    ]
    (spans "json" "[-2.5, 3]");
  (* A sign with no digit after it is not a number, and must not stop the
     lexer either. *)
  check Alcotest.(list string) "a lone sign stays plain"
    [ Masc_tui_code_lexer.kind_code ]
    (List.sort_uniq compare (List.map snd (spans "json" "{-}")))

(* Every branch of every lexer has to move the cursor. One that does not
   turns opening a file into a frozen TUI, and no assertion catches it: the
   lexer never answers, right or wrong. So this asks the only question that
   can be asked -- does it come back -- for the fragments that make a branch
   read one character and decide something about the next one. The alarm
   turns a hang into a failed test naming the case in flight, instead of a
   CI job that runs until its own timeout. *)
let awkward_fragments =
  [ ""; " "; "\n"; "\t"; "-"; "-1"; "--"; "---"; "+"; "0x"; "0x_"; "1e"; "1.";
    ".5"; "e-"; "'"; "\""; "`"; "'''"; "\"\"\""; "\\"; "/*"; "*/"; "//"; "#";
    "{"; "}"; "["; "]"; ":"; ": -"; "= -"; "@@"; "$"; "<<"; ">>";
    {|{"a": -1}|}; "[-2.5, 3]"; "a = -1"; "x: -1"; "select -1"; "let x = -1";
    "echo -1" ]

let lexer_languages =
  [ "ocaml"; "bash"; "json"; "diff"; "memory"; "yaml"; "toml"; "sql";
    "typescript"; "go"; "rust"; "c"; "python" ]

let test_every_lexer_finishes_on_awkward_fragments () =
  let in_flight = ref "" in
  under_alarm 10
    (fun () -> !in_flight)
    (fun () ->
      List.iter
        (fun language ->
          match Masc_tui_code_lexer.lexer_of_language language with
          | None -> Alcotest.failf "no lexer for %s" language
          | Some lex ->
            List.iter
              (fun fragment ->
                in_flight := Printf.sprintf "%s on %S" language fragment;
                ignore (List.length (lex fragment)))
              awkward_fragments)
        lexer_languages);
  Alcotest.(check bool) "every lexer answered" true true

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
        ; Alcotest.test_case
            "assignment rows ignore strings and comments"
            `Quick test_assignment_rows_ignore_strings_and_comments
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
        ; Alcotest.test_case "a digit inside a scalar is not a value" `Quick
            test_a_digit_inside_a_scalar_is_not_a_value
        ; Alcotest.test_case "a literal inside a scalar is not a literal" `Quick
            test_a_literal_inside_a_scalar_is_not_a_literal
        ; Alcotest.test_case "memory reads the sign and the category" `Quick
            test_memory_reads_the_sign_and_the_category
        ; Alcotest.test_case "the categories group rather than collide" `Quick
            test_the_categories_group_rather_than_collide
        ; Alcotest.test_case "a drop line is the quietest row" `Quick
            test_a_drop_line_is_the_quietest_row
        ; Alcotest.test_case "toml reads a key, a string and a comment" `Quick
            test_toml_reads_a_key_a_string_and_a_comment
        ; Alcotest.test_case "a toml table header is taken whole" `Quick
            test_a_toml_table_header_is_taken_whole
        ; Alcotest.test_case "json reads a negative number" `Quick
            test_json_reads_a_negative_number
        ; Alcotest.test_case "every lexer finishes on awkward fragments" `Quick
            test_every_lexer_finishes_on_awkward_fragments
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
