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

let () =
  Alcotest.run "Exact chart count shares"
    [ "numeric decisions",
      [ Alcotest.test_case "decimal boundaries and floor" `Quick exact_decimal_boundaries
      ; Alcotest.test_case "large totals and products" `Quick large_counts
      ; Alcotest.test_case "empty and negative inputs" `Quick empty_and_negative_inputs
      ]
    ]
