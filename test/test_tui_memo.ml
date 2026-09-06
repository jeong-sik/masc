(* Memos read off lexed rows: the row must be a comment and nothing else,
   and the line number is the one the gutter draws. *)

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

let test_only_a_row_that_is_a_comment_carries_a_memo () =
  let source =
    String.concat "\n"
      [ "let a = 1"
      ; "(* masc(alpha): the lock is held across the await on purpose *)"
      ; "let b = a (* masc(alpha): beside code, so a comment about it *)"
      ; "  (* masc(beta) question: why not batch this *)"
      ; "(* an ordinary comment *)"
      ; ""
      ]
  in
  Alcotest.(check (list found)) "two memos, on their own rows"
    [ Masc_tui_memo.Memo_at
        (2, memo "alpha" Agent_observation.Comment "the lock is held across the await on purpose")
    ; Masc_tui_memo.Memo_at (4, memo "beta" Agent_observation.Question "why not batch this")
    ]
    (Masc_tui_memo.of_rows (rows ~language:(Some "ocaml") source))

let test_an_indented_hash_memo_is_found () =
  let source = "def f():\n    # masc(ci.bot-2) bookmark: start here\n    return 1\n" in
  Alcotest.(check (list found)) "the python row"
    [ Masc_tui_memo.Memo_at (2, memo "ci.bot-2" Agent_observation.Bookmark "start here") ]
    (Masc_tui_memo.of_rows (rows ~language:(Some "python") source))

let test_a_memo_that_stops_short_is_listed_as_broken () =
  let source = "int x;\n// masc(alpha) verdict: no\n" in
  Alcotest.(check (list found)) "the reason travels"
    [ Masc_tui_memo.Broken_at (2, "unknown kind verdict") ]
    (Masc_tui_memo.of_rows (rows ~language:(Some "c") source))

let test_a_file_without_a_lexer_yields_nothing () =
  Alcotest.(check (list found)) "no comment tokens, no memos" []
    (Masc_tui_memo.of_rows (rows ~language:None "(* masc(alpha): x *)\n"))

let () =
  Alcotest.run "tui_memo"
    [ ( "rows"
      , [ Alcotest.test_case "only a row that is a comment carries a memo" `Quick
            test_only_a_row_that_is_a_comment_carries_a_memo
        ; Alcotest.test_case "an indented hash memo is found" `Quick
            test_an_indented_hash_memo_is_found
        ; Alcotest.test_case "a memo that stops short is listed as broken" `Quick
            test_a_memo_that_stops_short_is_listed_as_broken
        ; Alcotest.test_case "a file without a lexer yields nothing" `Quick
            test_a_file_without_a_lexer_yields_nothing
        ] )
    ]
