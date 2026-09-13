(* The failure row: "(data unreliable: <error>)". A short error was padded out
   to the row's room, so on a wide terminal the closing bracket stood at the
   right edge of the frame and the words it closed ended far to its left. *)

let strip_sgr row =
  let buf = Buffer.create (String.length row) in
  let in_escape = ref false in
  String.iter
    (fun ch ->
      if !in_escape then (if ch = 'm' then in_escape := false)
      else if ch = '\027' then in_escape := true
      else Buffer.add_char buf ch)
    row;
  Buffer.contents buf

let row ~cols err = strip_sgr (Masc_tui_render_prim.data_unreliable_row ~cols err)

let test_short_error_closes_where_it_ends () =
  Alcotest.(check string) "bracket right after the error"
    "  (data unreliable: schedule load failed: HTTP 503)"
    (row ~cols:120 "schedule load failed: HTTP 503")

let test_long_error_is_cut_to_the_row () =
  let err = String.make 200 'x' in
  let drawn = row ~cols:80 err in
  let cut = "\xe2\x80\xa6)" in
  Alcotest.(check bool) "cut mark before the bracket" true
    (String.ends_with ~suffix:cut drawn);
  (* 80 columns leave 76 inside the frame. The cut mark is three bytes and
     one cell, so the row spends two bytes more than it spends cells. *)
  Alcotest.(check int) "fills the frame's inner width" 76 (String.length drawn - 2)

let () =
  Alcotest.run "tui_data_unreliable_row"
    [ ( "data unreliable row"
      , [ Alcotest.test_case "short error closes where it ends" `Quick
            test_short_error_closes_where_it_ends
        ; Alcotest.test_case "long error is cut to the row" `Quick
            test_long_error_is_cut_to_the_row
        ] )
    ]
