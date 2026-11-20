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

let contains_sub ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  let rec scan i =
    i + nlen <= hlen
    && (String.equal (String.sub haystack i nlen) needle || scan (i + 1))
  in
  scan 0

let test_dropped_badge_preserves_right_aligned_headers () =
  let cells_en =
    [ Table.cell ~align:Table.Left ~header:"NAME" ~width:28 ""
    ; Table.cell ~align:Table.Right ~header:"SCORE" ~width:7 ""
    ; Table.cell ~align:Table.Right ~header:"REPLIES" ~width:7 ""
    ]
  in
  let inner_width = Table.used_width cells_en in
  let header_en =
    Table.header_row_with_dropped ~ko:false ~inner_width ~dropped:1 cells_en
  in
  check int "EN header keeps exact used_width" inner_width
    (Layout.display_width header_en);
  check bool "EN badge sits inside left-aligned slack" true
    (contains_sub ~needle:"NAME \xc2\xb7 1 more col" header_en);
  check bool "EN right-aligned SCORE preserved" true
    (contains_sub ~needle:"SCORE" header_en);
  check bool "EN right-aligned REPLIES preserved" true
    (contains_sub ~needle:"REPLIES" header_en);
  let cells_ko =
    [ Table.cell ~align:Table.Left ~header:"제목" ~width:24 ""
    ; Table.cell ~align:Table.Right ~header:"점수" ~width:6 ""
    ; Table.cell ~align:Table.Right ~header:"댓글" ~width:6 ""
    ]
  in
  let inner_ko = Table.used_width cells_ko in
  let header_ko =
    Table.header_row_with_dropped ~ko:true ~inner_width:inner_ko ~dropped:2 cells_ko
  in
  check int "KO header keeps exact used_width" inner_ko
    (Layout.display_width header_ko);
  check bool "KO badge sits inside left-aligned slack" true
    (contains_sub ~needle:"제목 \xc2\xb7 외 2열" header_ko);
  check bool "KO right-aligned 점수 preserved" true
    (contains_sub ~needle:"점수" header_ko);
  check bool "KO right-aligned 댓글 preserved" true
    (contains_sub ~needle:"댓글" header_ko);
  (* When [used_width cells > inner_width] (all droppable columns already gone
     and flex hit its floor), the badge must still stay inside [inner_width]
     even if a left-aligned trailing column has large per-cell slack. *)
  let overflow_cells =
    [ Table.cell ~align:Table.Left ~header:"커넥터" ~width:12 ""
    ; Table.cell ~align:Table.Left ~header:"연결" ~width:9 ""
    ; Table.cell ~align:Table.Left ~header:"상태" ~width:12 ""
    ; Table.cell ~align:Table.Left ~header:"채널" ~width:16 ""
    ]
  in
  let overflow_hdr =
    Table.header_row_with_dropped ~ko:true ~inner_width:44 ~dropped:1 overflow_cells
  in
  check bool "overflowing table header stays within inner_width" true
    (Layout.display_width overflow_hdr <= 44);
  check bool "overflowing table header keeps dropped badge visible" true
    (contains_sub ~needle:"외 1열" overflow_hdr)

let () =
  run "Masc_tui_table"
    [ ( "layout and overflow"
      , [ test_case "cell gap is two cells" `Quick test_cell_gap_is_two_cells
        ; test_case "fit tracks dropped columns" `Quick test_fit_tracks_dropped_columns
        ; test_case "dropped columns badge and header width" `Quick
            test_dropped_columns_badge_and_header_width
        ; test_case "dropped badge preserves right-aligned trailing headers" `Quick
            test_dropped_badge_preserves_right_aligned_headers
        ] )
    ]
