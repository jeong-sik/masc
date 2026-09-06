(* Memos read off a file's rows in its own comment syntax: the row must be
   one comment in the file's markers and nothing else, and the line number
   is the one the gutter draws. *)

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
let block opens closes = Ide_memo.Block { opens; closes }

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
        (2, memo "alpha" Agent_observation.Comment "the lock is held across the await on purpose")
    ; Masc_tui_memo.Memo_at (4, memo "beta" Agent_observation.Question "why not batch this")
    ]
    (Masc_tui_memo.of_rows ~markers:(block "(*" "*)") (rows ~language:(Some "ocaml") source))

let test_an_indented_hash_memo_is_found () =
  let source = "def f():\n    # masc(ci.bot-2) bookmark: start here\n    return 1\n" in
  Alcotest.(check (list found)) "the python row"
    [ Masc_tui_memo.Memo_at (2, memo "ci.bot-2" Agent_observation.Bookmark "start here") ]
    (Masc_tui_memo.of_rows ~markers:(Ide_memo.Line "#") (rows ~language:(Some "python") source))

let test_a_memo_that_stops_short_is_listed_as_broken () =
  let source = "int x;\n// masc(alpha) verdict: no\n" in
  Alcotest.(check (list found)) "the reason travels"
    [ Masc_tui_memo.Broken_at (2, "unknown kind verdict") ]
    (Masc_tui_memo.of_rows ~markers:(Ide_memo.Line "//") (rows ~language:(Some "c") source))

(* Lua has no lexer here, so its rows arrive as plain text. The markers
   are what make the memo readable, not the lexer. *)
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
    (Masc_tui_memo.of_rows ~markers:(Ide_memo.Line "--") (rows ~language:None source))

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
    (Masc_tui_memo.of_rows ~markers:(block "<!--" "-->") (rows ~language:None source))

(* The reader looks for the marker the writer uses for the file, so a
   hash line in a C file is not a memo: C spells one with //. *)
let test_only_the_files_own_marker_is_read () =
  let source = "# masc(alpha): x\n// masc(alpha): y\n" in
  Alcotest.(check (list found)) "the // row"
    [ Masc_tui_memo.Memo_at (2, memo "alpha" Agent_observation.Comment "y") ]
    (Masc_tui_memo.of_rows ~markers:(Ide_memo.Line "//") (rows ~language:(Some "c") source))

let test_of_file_reads_what_the_writer_would_write () =
  let lua = rows ~language:None "-- masc(alpha): x\n" in
  Alcotest.(check (list found)) "notes.lua"
    [ Masc_tui_memo.Memo_at (1, memo "alpha" Agent_observation.Comment "x") ]
    (Masc_tui_memo.of_file ~path:"src/notes.lua" lua);
  Alcotest.(check (list found)) "json has no comment, so no memo"
    [] (Masc_tui_memo.of_file ~path:"data.json" (rows ~language:(Some "json") "// masc(alpha): x\n"));
  Alcotest.(check (list found)) "an extension no language covers"
    [] (Masc_tui_memo.of_file ~path:"notes.cobol" (rows ~language:None "// masc(alpha): x\n"))

let () =
  Alcotest.run "tui_memo"
    [ ( "rows"
      , [ Alcotest.test_case "only a row that is a comment carries a memo" `Quick
            test_only_a_row_that_is_a_comment_carries_a_memo
        ; Alcotest.test_case "an indented hash memo is found" `Quick
            test_an_indented_hash_memo_is_found
        ; Alcotest.test_case "a memo that stops short is listed as broken" `Quick
            test_a_memo_that_stops_short_is_listed_as_broken
        ; Alcotest.test_case "a language without a lexer reads by its markers" `Quick
            test_a_language_without_a_lexer_reads_by_its_markers
        ; Alcotest.test_case "a block marker must close on the row" `Quick
            test_a_block_marker_must_close_on_the_row
        ; Alcotest.test_case "only the file's own marker is read" `Quick
            test_only_the_files_own_marker_is_read
        ; Alcotest.test_case "of_file reads what the writer would write" `Quick
            test_of_file_reads_what_the_writer_would_write
        ] )
    ]
