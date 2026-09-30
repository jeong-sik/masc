(** Missing values use a one-column mark; removed diff rows keep their source marker. *)

let mark = Masc_tui_theme.Glyph.no_value

let test_missing_value_cell () =
  Alcotest.(check string) "missing value" "\xe2\x80\x94" mark;
  Alcotest.(check int) "one terminal column" 1
    (Masc_tui_message_layout.display_width mark);
  Alcotest.(check string) "aligned missing-value cell" (mark ^ "     ")
    (Masc_tui_message_layout.fit_width mark 6)
;;

let test_removed_diff_marker () =
  let rows =
    Masc_tui_markdown.render ~palette:Masc_tui_markdown.plain_palette ~width:12
      "```diff\n-gone\n+here\n```"
  in
  Alcotest.(check bool) "removed source stays identifiable without colour" true
    (List.exists (fun row -> String.equal (String.trim row) "| -gone") rows);
  Alcotest.(check bool) "added source stays distinct" true
    (List.exists (fun row -> String.equal (String.trim row) "| +here") rows)
;;

let () =
  Alcotest.run "tui_no_value_mark"
    [ ( "no value mark"
      , [ Alcotest.test_case "missing-value cell stays aligned" `Quick
            test_missing_value_cell
        ; Alcotest.test_case "removed diff retains its marker" `Quick
            test_removed_diff_marker
        ] )
    ]
;;
