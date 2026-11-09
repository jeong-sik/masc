module Chart = Masc_tui_chart

let check_shares label ~cells counts expected =
  let actual = Chart.distribution_shares ~cells counts
    |> List.map (fun (share : Chart.distribution_share) ->
      share.percentage, share.filled_cells) in
  Alcotest.(check (list (pair int int))) label expected actual

let exact_decimal_boundaries () =
  check_shares "29 and 57 are exact percentages and cells" ~cells:100
    [29; 57; 14] [29, 29; 57, 57; 14, 14];
  check_shares "29 of 50 is exactly 58 percent" ~cells:50
    [29; 21] [58, 29; 42, 21];
  check_shares "fractional shares round down independently" ~cells:10
    [1; 1; 1] [33, 3; 33, 3; 33, 3]

let large_counts () =
  check_shares "sum and scaled product may both exceed max_int" ~cells:100
    [max_int; max_int] [50, 50; 50, 50];
  check_shares "unit difference remains below the 50-percent boundary" ~cells:100
    [max_int; max_int - 1] [50, 50; 49, 49];
  check_shares "sum can exceed Int64.max_int" ~cells:100
    [max_int; max_int; max_int; max_int; max_int]
    [20, 20; 20, 20; 20, 20; 20, 20; 20, 20];
  check_shares "largest cell scale also uses exact multiplication" ~cells:max_int
    [max_int; max_int] [50, max_int / 2; 50, max_int / 2];
  check_shares "single full share remains representable" ~cells:max_int
    [max_int] [100, max_int]

let empty_and_negative_inputs () =
  check_shares "empty" ~cells:100 [] [];
  check_shares "nonpositive counts have no share" ~cells:100
    [min_int; 0; -1] [0, 0; 0, 0; 0, 0];
  check_shares "negative counts do not enter the denominator" ~cells:100
    [-1; 29; 71] [0, 0; 29, 29; 71, 71];
  check_shares "negative capacity keeps percentages but has no cells" ~cells:min_int
    [29; 71] [29, 0; 71, 0]

let sparkline_levels () =
  let check = Alcotest.(check (list int)) in
  check "large nonnegative values retain the full scale" [0; 7]
    (Chart.sparkline_levels [0; max_int]);
  check "the full integer range does not overflow" [0; 3; 7]
    (Chart.sparkline_levels [min_int; 0; max_int]);
  check "explicit bounds clamp values" [0; 1; 7; 7]
    (Chart.sparkline_levels ~min:0 ~max:100 [-5; 25; 100; 500]);
  check "a constant positive series uses the middle" [3; 3]
    (Chart.sparkline_levels [4; 4]);
  check "a constant zero series uses the lowest level" [0; 0]
    (Chart.sparkline_levels [0; 0])

let compact_number_boundaries () =
  let check = Alcotest.(check string) in
  check "min_int prints as its exact integer, not a made-up rung"
    (string_of_int min_int)
    (Chart.format_compact_num min_int);
  check "one above min_int keeps its negative magnitude rung"
    "-4611686018427.4M"
    (Chart.format_compact_num (min_int + 1));
  check "a million keeps the M rung" "-2.0M" (Chart.format_compact_num (-2_000_000));
  check "ten thousand keeps the k rung" "-10k" (Chart.format_compact_num (-10_000));
  check "a thousand and a half keeps one decimal" "-1.5k"
    (Chart.format_compact_num (-1_500));
  check "below a thousand is the plain integer" "999" (Chart.format_compact_num 999)

let bar_filled_cells () =
  let check name expected ~value ~max_value =
    Alcotest.(check int) name expected (Chart.bar_filled_cells ~width:8 ~value ~max_value)
  in
  check "nothing fills no cell" 0 ~value:0 ~max_value:10;
  check "a negative value fills no cell" 0 ~value:(-3) ~max_value:10;
  check "no maximum fills no cell" 0 ~value:3 ~max_value:0;
  check "a small value still fills one cell" 1 ~value:1 ~max_value:100;
  check "half the maximum fills half the cells" 4 ~value:5 ~max_value:10;
  check "the maximum fills every cell" 8 ~value:10 ~max_value:10;
  check "past the maximum fills every cell" 8 ~value:500 ~max_value:10;
  Alcotest.(check int) "a bar with no cells fills none" 0
    (Chart.bar_filled_cells ~width:0 ~value:5 ~max_value:10)

let () =
  Alcotest.run "Chart numeric decisions"
    [ "numeric decisions",
      [ Alcotest.test_case "decimal boundaries and floor" `Quick exact_decimal_boundaries
      ; Alcotest.test_case "large totals and products" `Quick large_counts
      ; Alcotest.test_case "empty and negative inputs" `Quick empty_and_negative_inputs
      ; Alcotest.test_case "sparkline scale and integer limits" `Quick sparkline_levels
      ; Alcotest.test_case "compact number boundaries" `Quick compact_number_boundaries
      ; Alcotest.test_case "bar fill" `Quick bar_filled_cells
      ]
    ]
