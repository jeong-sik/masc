(* Decision tests for Masc_tui_table: two-cell column gap, dropped-column
   counting in [fit], and overflow badge geometry on narrow headers
   (RFC tui-one-screen-grammar sections 2 and 5.1). *)

open Alcotest
module Table = Masc_tui_table
module Layout = Masc_tui_message_layout

type col =
  | Col_name
  | Col_status
  | Col_extra_1
  | Col_extra_2

let col_width = function
  | Col_name -> 10
  | Col_status -> 8
  | Col_extra_1 -> 10
  | Col_extra_2 -> 10

let test_cell_gap_is_two_cells () =
  check int "column gap" 2 Table.cell_gap;
  let cells =
    [ Table.cell ~header:"A" ~width:4 "a"
    ; Table.cell ~header:"B" ~width:6 "b"
    ]
  in
  check int "used_width includes two-cell gap" 12 (Table.used_width cells)

let test_fit_tracks_dropped_columns () =
  let columns = [ Col_name; Col_status; Col_extra_1; Col_extra_2 ] in
  let drop_order = [ Col_extra_2; Col_extra_1 ] in
  let wide =
    Table.fit ~inner_width:60 ~width:col_width ~flex:Col_name ~drop_order columns
  in
  check int "wide keeps all columns" 0 wide.dropped;
  check int "wide shown count" 4 (List.length wide.shown);
  let medium =
    Table.fit ~inner_width:32 ~width:col_width ~flex:Col_name ~drop_order columns
  in
  check int "medium drops one column" 1 medium.dropped;
  check int "medium shown count" 3 (List.length medium.shown);
  let narrow =
    Table.fit ~inner_width:20 ~width:col_width ~flex:Col_name ~drop_order columns
  in
  check int "narrow drops both optional columns" 2 narrow.dropped;
  check int "narrow shown count" 2 (List.length narrow.shown)

let test_dropped_columns_badge_and_header_width () =
  check (option string) "zero dropped emits none" None
    (Table.dropped_columns_badge ~ko:true 0);
  check (option string) "korean badge" (Some "외 2열")
    (Table.dropped_columns_badge ~ko:true 2);
  check (option string) "english singular badge" (Some "1 more col")
    (Table.dropped_columns_badge ~ko:false 1);
  check (option string) "english plural badge" (Some "2 more cols")
    (Table.dropped_columns_badge ~ko:false 2);
  let cells =
    [ Table.cell ~header:"이름" ~width:12 ""
    ; Table.cell ~header:"상태" ~width:8 ""
    ]
  in
  let header =
    Table.header_row_with_dropped ~ko:true ~inner_width:30 ~dropped:2 cells
  in
  check int "header with badge fits inner_width" 30 (Layout.display_width header);
  (* A [Table.fit] layout fills [inner_width] with trailing padding on the last
     column; the badge must reuse that padding instead of inserting ["…"]. The
     last shown header is short so its cell leaves the eight cells the gap and
     the badge need: a header that fills its cell leaves none, and the badge
     then cuts the header. *)
  let fitted =
    Table.fit ~inner_width:32 ~width:col_width ~flex:Col_name
      ~drop_order:[ Col_extra_2; Col_extra_1 ]
      [ Col_name; Col_status; Col_extra_1; Col_extra_2 ]
  in
  let fitted_cells =
    List.map
      (fun col ->
         let header =
           match col with
           | Col_name -> "NAME"
           | Col_status -> "STATE"
           | Col_extra_1 -> "X1"
           | Col_extra_2 -> "EXTRA2"
         in
         let width = if col = Col_name then fitted.flex_width else col_width col in
         Table.cell ~header ~width "")
      fitted.shown
  in
  let fitted_header =
    Table.header_row_with_dropped ~ko:false ~inner_width:32 ~dropped:fitted.dropped fitted_cells
  in
  check int "fit-derived header keeps inner_width" 32 (Layout.display_width fitted_header);
  check bool "fit-derived header reuses trailing padding without ellipsis" false
    (String.contains fitted_header '\xe2' && String.ends_with ~suffix:"…  +1 col" fitted_header);
  let tight =
    Table.header_row_with_dropped ~ko:true ~inner_width:18 ~dropped:2 cells
  in
  check int "tight header trims base rather than overflowing" 18
    (Layout.display_width tight)

let () =
  run "Masc_tui_table"
    [ ( "layout and overflow"
      , [ test_case "cell gap is two cells" `Quick test_cell_gap_is_two_cells
        ; test_case "fit tracks dropped columns" `Quick test_fit_tracks_dropped_columns
        ; test_case "dropped columns badge and header width" `Quick
            test_dropped_columns_badge_and_header_width
        ] )
    ]
