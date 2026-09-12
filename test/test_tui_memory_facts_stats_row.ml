open Alcotest
module Render_memory = Masc_tui_render_memory

(* The row under the facts title. Each fact on this screen is written in one
   place: the title carries the total and the category filter, this row carries
   the breakdown and the sort. Both used to carry the total, and both used to
   carry the sort, and the title is the row that runs out of width first -- at
   140 columns against a live server it was cut mid-timestamp, taking the clock
   and the connection badge with it. *)

let plain text = Masc_tui_theme.strip_sgr text

let row ?(ordinary = 282) ?(source = 0) ?(dropped = 3)
    ?(sort_label = "Recency (Newest)") () =
  plain
    (Render_memory.facts_stats_row ~ordinary ~source ~dropped ~sort_label)

let test_the_row_carries_the_breakdown_and_the_sort () =
  check string "what the title does not say"
    "  (282 ord \xc2\xb7 0 src \xc2\xb7 3 drop) \xc2\xb7 Sort [s]: Recency (Newest)"
    (row ())

let test_the_total_is_not_repeated_here () =
  (* 282 + 0 + 3 = 285, which the title draws as "(285 facts ...)". A row that
     adds them up again is the same fact twice. *)
  check bool "no total on this row" false
    (let text = row () in
     let needle = "285" in
     let n = String.length needle in
     let rec seek i =
       i + n <= String.length text
       && (String.equal (String.sub text i n) needle || seek (i + 1))
     in
     seek 0);
  check bool "and no word for it either" false
    (let text = row () in
     let needle = "Total" in
     let n = String.length needle in
     let rec seek i =
       i + n <= String.length text
       && (String.equal (String.sub text i n) needle || seek (i + 1))
     in
     seek 0)

let test_the_sort_travels_with_the_breakdown () =
  check string "another order, same shape"
    "  (1 ord \xc2\xb7 2 src \xc2\xb7 0 drop) \xc2\xb7 Sort [s]: Claim (A-Z)"
    (row ~ordinary:1 ~source:2 ~dropped:0 ~sort_label:"Claim (A-Z)" ())

let () =
  run "tui memory facts stats row"
    [ ( "one place per fact"
      , [ test_case "the row carries the breakdown and the sort" `Quick
            test_the_row_carries_the_breakdown_and_the_sort
        ; test_case "the total is not repeated here" `Quick
            test_the_total_is_not_repeated_here
        ; test_case "the sort travels with the breakdown" `Quick
            test_the_sort_travels_with_the_breakdown
        ] )
    ]
