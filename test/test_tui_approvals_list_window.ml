(* The Approvals queue's window: which rows it draws and what its line says.
   The PTY scenario (test_tui_approvals_window_pty.py) shows the screen; this
   table pins the arithmetic at the edges a three-row fixture cannot reach --
   a queue exactly the size of its rows, and a surface left with one row. *)

module R = Masc_tui_approvals_window

(* body_rows, total, window line drawn, some rows hidden, rows the window draws *)
let rows_table =
  [ 0, 0, false, false, 0
  ; 0, 3, false, true, 0
  ; 1, 1, false, false, 1
  ; 1, 2, false, true, 1 (* one row left: nothing to spend on a line *)
  ; 1, 9, false, true, 1
  ; 2, 1, false, false, 2
  ; 2, 2, false, false, 2 (* exactly full: nothing hidden, no line *)
  ; 2, 3, true, true, 1 (* the 80x17 case: one row, one line *)
  ; 5, 5, false, false, 5
  ; 5, 6, true, true, 4
  ; 5, 40, true, true, 4
  ]

let test_rows () =
  List.iter
    (fun (body_rows, total, overflows, hides, rows) ->
      let label field = Printf.sprintf "body_rows=%d total=%d: %s" body_rows total field in
      Alcotest.(check bool) (label "window line") overflows
        (R.overflows ~body_rows ~total);
      Alcotest.(check bool) (label "rows hidden") hides
        (R.hides_rows ~body_rows ~total);
      Alcotest.(check int) (label "rows drawn") rows
        (R.rows ~body_rows ~total))
    rows_table
;;

let test_drawn_plus_line_never_exceeds_body () =
  for body_rows = 0 to 12 do
    for total = 0 to 30 do
      let line = if R.overflows ~body_rows ~total then 1 else 0 in
      let drawn = min total (R.rows ~body_rows ~total) in
      Alcotest.(check bool)
        (Printf.sprintf "body_rows=%d total=%d: rows + line fit" body_rows total)
        true
        (drawn + line <= body_rows);
      (* A window line without hidden rows would be noise. *)
      if line = 1 then
        Alcotest.(check bool)
          (Printf.sprintf "body_rows=%d total=%d: the line has something to say" body_rows total)
          true
          (R.hides_rows ~body_rows ~total)
    done
  done
;;

(* scroll, height, total, the text the line reads from "[approvals" on *)
let note_table =
  [ 0, 1, 3, "[approvals 1-1/3]  2 more below -- j/k to reach"
  ; 1, 1, 3, "[approvals 2-2/3]  1 above \xc2\xb7 1 below -- j/k to reach"
  ; 2, 1, 3, "[approvals 3-3/3]  2 more above -- j/k to reach"
  ; 0, 4, 6, "[approvals 1-4/6]  2 more below -- j/k to reach"
  ; 2, 4, 6, "[approvals 3-6/6]  2 more above -- j/k to reach"
  ]

let test_note () =
  List.iter
    (fun (scroll, height, total, expected) ->
      Alcotest.(check string)
        (Printf.sprintf "scroll=%d height=%d total=%d" scroll height total)
        expected
        (R.note ~scroll ~height ~total))
    note_table
;;

let () =
  Alcotest.run
    "tui_approvals_list_window"
    [ ( "window"
      , [ Alcotest.test_case "rows table" `Quick test_rows
        ; Alcotest.test_case "drawn rows and the line fit the body" `Quick
            test_drawn_plus_line_never_exceeds_body
        ; Alcotest.test_case "the window line text" `Quick test_note
        ] )
    ]
;;
