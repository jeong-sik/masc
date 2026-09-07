(* Memos read off a file's rows. Where the TUI lexes the file the lexer says
   which rows are comments; where it does not, the file's markers do. The
   line number is the one the gutter draws. *)

let found =
  Alcotest.testable
    (fun fmt f ->
      match f with
      | Masc_tui_memo.Memo_at (line, memo) ->
        Format.fprintf fmt "L%d %s" line (Ide_memo.to_body memo)
      | Masc_tui_memo.Broken_at (line, why) -> Format.fprintf fmt "L%d broken: %s" line why)
    ( = )

let rows ~language source = Masc_tui_code_lexer.rows_of_source ~language source
let memo author kind text = { Ide_memo.author; kind; text }
let plain author text = memo author Agent_observation.Comment text

(* Reading a file the way the TUI does when it opens one: the path picks the
   reader, and the same path picks the lexer that produced the rows. *)
let of_path path source =
  Masc_tui_memo.of_file ~path
    (rows ~language:(Masc_tui_code_lexer.language_of_path path) source)

let test_only_a_row_that_is_a_comment_carries_a_memo () =
  let source =
    String.concat "\n"
      [ "let a = 1"
      ; "(* masc(alpha): the lock is held across the await on purpose *)"
      ; "let b = a (* masc(alpha): beside code, so a comment about it *)"
      ; "  (* masc(beta) question: why not batch this *)"
      ; "(* an ordinary comment *)"
      ; "(* masc(gamma): opened here"
      ; "   and closed here *)"
      ; ""
      ]
  in
  Alcotest.(check (list found)) "two memos, on their own rows"
    [ Masc_tui_memo.Memo_at
        (2, plain "alpha" "the lock is held across the await on purpose")
    ; Masc_tui_memo.Memo_at (4, memo "beta" Agent_observation.Question "why not batch this")
    ]
    (of_path "lib/a.ml" source)

let test_an_indented_hash_memo_is_found () =
  let source = "def f():\n    # masc(ci.bot-2) bookmark: start here\n    return 1\n" in
  Alcotest.(check (list found)) "the python row"
    [ Masc_tui_memo.Memo_at (2, memo "ci.bot-2" Agent_observation.Bookmark "start here") ]
    (of_path "tools/f.py" source)

let test_a_memo_that_stops_short_is_listed_as_broken () =
  let source = "int x;\n// masc(alpha) verdict: no\n" in
  Alcotest.(check (list found)) "the reason travels"
    [ Masc_tui_memo.Broken_at (2, "unknown kind verdict") ]
    (of_path "src/a.c" source)

(* The lexer knows a string from a comment; a single row does not. A memo
   the writer could never have put there must not be listed as one. *)
let test_a_marker_inside_a_string_is_not_a_memo () =
  let ocaml = "let s = \"one\n(* masc(alpha) decision: inside a string *)\nthree\"\n" in
  Alcotest.(check (list found)) "the ocaml string" [] (of_path "lib/a.ml" ocaml);
  let python = "s = \"\"\"\n# masc(alpha) decision: inside a docstring\n\"\"\"\n" in
  Alcotest.(check (list found)) "the python docstring" [] (of_path "tools/f.py" python)

(* A C file spells a memo with //, and the block form is a comment there
   too. The lexer says both rows are comments, so both are read. *)
let test_a_lexed_file_reads_either_comment_form () =
  let source = "/* masc(alpha): the block form */\n// masc(beta): the line form\n" in
  Alcotest.(check (list found)) "both rows"
    [ Masc_tui_memo.Memo_at (1, plain "alpha" "the block form")
    ; Masc_tui_memo.Memo_at (2, plain "beta" "the line form")
    ]
    (of_path "src/a.c" source)

(* The config this repo is configured by is TOML, and the TUI lexes it. *)
let test_a_toml_memo_is_found () =
  let source = "[keeper]\n# masc(alpha) decision: this cadence is deliberate\nname = \"a\"\n" in
  Alcotest.(check (list found)) "the toml row"
    [ Masc_tui_memo.Memo_at (2, memo "alpha" Agent_observation.Decision "this cadence is deliberate") ]
    (of_path "config/keepers/alpha.toml" source)

(* Lua has no lexer here, so the markers are what make the memo readable. *)
let test_a_language_without_a_lexer_reads_by_its_markers () =
  let source =
    String.concat "\n"
      [ "local x = 1"
      ; "-- masc(alpha) decision: keep the coroutine"
      ; "local y = x -- masc(alpha): beside code"
      ; ""
      ]
  in
  Alcotest.(check (list found)) "the lua row on its own"
    [ Masc_tui_memo.Memo_at (2, memo "alpha" Agent_observation.Decision "keep the coroutine") ]
    (of_path "src/init.lua" source)

let test_a_block_marker_must_close_on_the_row () =
  let source =
    String.concat "\n"
      [ "# Title"
      ; "<!-- masc(alpha) bookmark: start here -->"
      ; "<!-- masc(beta): not closed on this row"
      ; "-->"
      ; ""
      ]
  in
  Alcotest.(check (list found)) "only the closed html comment"
    [ Masc_tui_memo.Memo_at (2, memo "alpha" Agent_observation.Bookmark "start here") ]
    (of_path "notes/readme.md" source)

(* The reader looks for the marker the writer uses for the file, so a hash
   line in a Lua file is not a memo: Lua spells one with --. *)
let test_only_the_files_own_marker_is_read () =
  let source = "# masc(alpha): x\n-- masc(alpha): y\n" in
  Alcotest.(check (list found)) "the -- row"
    [ Masc_tui_memo.Memo_at (2, plain "alpha" "y") ]
    (of_path "src/init.lua" source)

(* A file written on Windows carries a carriage return the wire escapes;
   it is not part of the comment. *)
let test_a_carriage_return_does_not_hide_a_memo () =
  let markdown = "# Title\\x0D\n<!-- masc(alpha) bookmark: start here -->\\x0D\n" in
  Alcotest.(check (list found)) "the markdown row"
    [ Masc_tui_memo.Memo_at (2, memo "alpha" Agent_observation.Bookmark "start here") ]
    (of_path "notes/readme.md" markdown);
  let ocaml = "(* masc(alpha): the lock is deliberate *)\\x0D\n" in
  Alcotest.(check (list found)) "the ocaml row"
    [ Masc_tui_memo.Memo_at (1, plain "alpha" "the lock is deliberate") ]
    (of_path "lib/a.ml" ocaml)

let test_a_file_the_tui_cannot_spell_a_memo_in_yields_nothing () =
  Alcotest.(check (list found)) "an extension no language covers"
    [] (of_path "notes.cobol" "// masc(alpha): x\n")

(* Every extension the writer accepts must read back, so a language added to
   one side cannot go missing on the other. *)
let test_every_writable_extension_reads_its_own_memo_back () =
  let written = memo "alpha" Agent_observation.Question "why three" in
  List.iter
    (fun extension ->
      match Lsp_process_manager.memo_line ~path:("a" ^ extension) written with
      | Error refusal ->
        (* JSON has no comment; the writer says so and there is nothing to read. *)
        (match refusal with
         | Lsp_process_manager.No_comment_syntax _ -> ()
         | Lsp_process_manager.Extension_unknown ext ->
           Alcotest.failf "the writer does not know %s" ext)
      | Ok line ->
        let path = "a" ^ extension in
        Alcotest.(check (list found))
          (extension ^ " reads its own memo back")
          [ Masc_tui_memo.Memo_at (1, written) ]
          (of_path path (line ^ "\n")))
    (Lsp_process_manager.covered_extensions ())

let () =
  Alcotest.run "tui_memo"
    [ ( "rows"
      , [ Alcotest.test_case "only a row that is a comment carries a memo" `Quick
            test_only_a_row_that_is_a_comment_carries_a_memo
        ; Alcotest.test_case "an indented hash memo is found" `Quick
            test_an_indented_hash_memo_is_found
        ; Alcotest.test_case "a memo that stops short is listed as broken" `Quick
            test_a_memo_that_stops_short_is_listed_as_broken
        ; Alcotest.test_case "a marker inside a string is not a memo" `Quick
            test_a_marker_inside_a_string_is_not_a_memo
        ; Alcotest.test_case "a lexed file reads either comment form" `Quick
            test_a_lexed_file_reads_either_comment_form
        ; Alcotest.test_case "a toml memo is found" `Quick test_a_toml_memo_is_found
        ; Alcotest.test_case "a language without a lexer reads by its markers" `Quick
            test_a_language_without_a_lexer_reads_by_its_markers
        ; Alcotest.test_case "a block marker must close on the row" `Quick
            test_a_block_marker_must_close_on_the_row
        ; Alcotest.test_case "only the file's own marker is read" `Quick
            test_only_the_files_own_marker_is_read
        ; Alcotest.test_case "a carriage return does not hide a memo" `Quick
            test_a_carriage_return_does_not_hide_a_memo
        ; Alcotest.test_case "a file the TUI cannot spell a memo in yields nothing" `Quick
            test_a_file_the_tui_cannot_spell_a_memo_in_yields_nothing
        ; Alcotest.test_case "every writable extension reads its own memo back" `Quick
            test_every_writable_extension_reads_its_own_memo_back
        ] )
    ]
