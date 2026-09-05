let check = Alcotest.check
let int = Alcotest.int
let string = Alcotest.string
let bool = Alcotest.bool

module Chart = Masc_tui_chart
module Layout = Masc_tui_message_layout

let test_sparkline_empty () =
  check string "empty sparkline is empty" "" (Chart.sparkline [])
;;

let test_sparkline_levels () =
  let values = [ 0; 10; 20; 30; 40; 50; 60; 70 ] in
  let result = Chart.sparkline values in
  check int "sparkline 8 characters" 8 (Layout.display_width result);
  let flat = Chart.sparkline [ 5; 5; 5; 5 ] in
  check int "flat sparkline 4 characters" 4 (Layout.display_width flat);
  let single = Chart.sparkline [ 42 ] in
  check int "single element 1 character" 1 (Layout.display_width single)
;;

let test_sparkline_colored () =
  let values = [ 10; 50; 90 ] in
  let colored =
    Chart.sparkline_colored
      ~style_of_level:(fun lvl ->
        if lvl >= 6 then Chart.Status Masc_tui_theme.Bad
        else if lvl >= 3 then Chart.Status Masc_tui_theme.Warn
        else Chart.Status Masc_tui_theme.Ok)
      values
  in
  check int "sparkline colored has 3 display cells" 3 (Layout.display_width colored)
;;

let test_gauge_proportions () =
  let g50 = Chart.gauge ~width:40 ~value:50 ~max_value:100 ~label:"Context" () in
  check int "gauge fits within 40 width" true (Layout.display_width g50 <= 40);
  (* zero max_value handles gracefully without divide-by-zero *)
  let g_zero = Chart.gauge ~width:30 ~value:10 ~max_value:0 () in
  check int "zero max fits within 30 width" true (Layout.display_width g_zero <= 30);
  (* narrow width strictly enforced *)
  let g_narrow = Chart.gauge ~width:10 ~value:75 ~max_value:100 () in
  check int "narrow gauge fits within 10 width" true (Layout.display_width g_narrow <= 10);
  (* zero width produces empty string *)
  let g_empty = Chart.gauge ~width:0 ~value:10 ~max_value:100 () in
  check string "empty width produces empty" "" g_empty
;;

let test_compact_number () =
  check string "small" "42" (Chart.format_compact_num 42);
  check string "thousands" "1.5k" (Chart.format_compact_num 1500);
  check string "ten thousands" "24k" (Chart.format_compact_num 24000);
  check string "millions" "2.5M" (Chart.format_compact_num 2500000);
  check string "min_int safe" "-4.6M" (Chart.format_compact_num min_int)
;;

let test_waterfall_chart () =
  let steps : Chart.waterfall_step list =
    [ { label = "Provider TTFT"; duration_ms = 300; style = Some (Chart.Status Masc_tui_theme.Info) }
    ; { label = "Stream Gen"; duration_ms = 700; style = Some (Chart.Tone Masc_tui_theme.Accent) }
    ]
  in
  let rows = Chart.waterfall ~width:60 steps in
  check int "two waterfall rows" 2 (List.length rows);
  List.iter
    (fun row ->
      check bool "waterfall row bounded by width" true (Layout.display_width row <= 60))
    rows;
  (* narrow width test *)
  let narrow_rows = Chart.waterfall ~width:25 steps in
  List.iter
    (fun row ->
      check bool "narrow waterfall row bounded by 25" true (Layout.display_width row <= 25))
    narrow_rows
;;

let test_heatmap_24h_normalization () =
  (* Morning peak: 2, Afternoon peak: 1000. Shared normalization must not show morning 2 as peak *)
  let hours = List.init 24 (fun i -> if i = 5 then 2 else if i = 18 then 1000 else 0) in
  let rows = Chart.heatmap_24h ~label:"Keeper Fleet" ~hours in
  check int "heatmap 24h produces 3 lines" 3 (List.length rows);
  check int "row1 has 24 display cells" 24 (Layout.display_width (List.nth rows 1));
  check int "row2 has 24 display cells" 24 (Layout.display_width (List.nth rows 2))
;;

let test_distribution_bars () =
  let items : Chart.bar_item list =
    [ { name = "상수_speak"; count = 50; style = Some (Chart.Status Masc_tui_theme.Ok) }
    ; { name = "run_command"; count = 25; style = None }
    ; { name = "replace_file"; count = 25; style = None }
    ]
  in
  let rows = Chart.distribution_bars ~width:50 items in
  check int "3 distribution rows" 3 (List.length rows);
  List.iter
    (fun row ->
      check bool "distribution row bounded by 50" true (Layout.display_width row <= 50))
    rows;
  (* narrow width constraint *)
  let narrow_rows = Chart.distribution_bars ~width:20 items in
  List.iter
    (fun row ->
      check bool "narrow distribution row bounded by 20" true (Layout.display_width row <= 20))
    narrow_rows
;;

let test_braille_curve () =
  let cell_blank = Chart.braille_cell ~mask:0 in
  check int "blank braille 1 cell" 1 (Layout.display_width cell_blank);
  let cell_full = Chart.braille_cell ~mask:0xff in
  check int "full braille 1 cell" 1 (Layout.display_width cell_full);
  let points = [ 0.0; 2.0; 8.0; 4.0; 1.0; 9.0; 3.0 ] in
  let plot = Chart.braille_plot ~width:20 ~height:4 points in
  check int "braille plot 4 rows" 4 (List.length plot);
  List.iter (fun row -> check int "row width 20 cells" 20 (Layout.display_width row)) plot;
  (* NaN / Inf resilience *)
  let nan_points = [ Float.nan; Float.infinity; 5.0; Float.neg_infinity ] in
  let nan_plot = Chart.braille_plot ~width:15 ~height:3 nan_points in
  check int "nan-safe braille plot 3 rows" 3 (List.length nan_plot)
;;

let () =
  Alcotest.run "masc_tui_chart"
    [ ( "sparklines"
      , [ Alcotest.test_case "empty" `Quick test_sparkline_empty
        ; Alcotest.test_case "levels" `Quick test_sparkline_levels
        ; Alcotest.test_case "colored" `Quick test_sparkline_colored
        ] )
    ; ( "gauges"
      , [ Alcotest.test_case "proportions" `Quick test_gauge_proportions
        ; Alcotest.test_case "compact_number" `Quick test_compact_number
        ] )
    ; ( "waterfall"
      , [ Alcotest.test_case "breakdown" `Quick test_waterfall_chart ] )
    ; ( "heatmap"
      , [ Alcotest.test_case "24h_normalization" `Quick test_heatmap_24h_normalization ] )
    ; ( "distribution"
      , [ Alcotest.test_case "bars" `Quick test_distribution_bars ] )
    ; ( "braille"
      , [ Alcotest.test_case "curve_plot" `Quick test_braille_curve ] )
    ]
;;
