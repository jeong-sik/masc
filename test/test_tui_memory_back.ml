(* Esc on Memory undoes the nearest layer: the filter, then the fact browser,
   then the surface. The keeper table said "[Esc to clear]" beside its filter
   and Esc left with the filter still set. *)

open Masc_tui_types

let state () = create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

let check_back what expected actual =
  Alcotest.(check bool) what true (expected = actual)

let test_table_filter_clears_before_leaving () =
  let s = state () in
  s.view <- Memory;
  s.search_last <- "alpha";
  s.memory_health_cursor <- 3;
  check_back "a filtered table stays" Memory_stays (memory_back s);
  Alcotest.(check string) "and drops the filter" "" s.search_last;
  Alcotest.(check int) "from the top of the whole list" 0 s.memory_health_cursor;
  check_back "an unfiltered table leaves" Memory_leaves (memory_back s)

let test_fact_browser_clears_then_closes () =
  let s = state () in
  s.view <- Memory;
  s.memory_facts_keeper <- Some "alpha";
  s.search_last <- "claim";
  check_back "a filtered browser stays" Memory_stays (memory_back s);
  Alcotest.(check string) "and drops the filter" "" s.search_last;
  Alcotest.(check (option string)) "with the browser still open" (Some "alpha")
    s.memory_facts_keeper;
  check_back "an unfiltered browser closes and stays" Memory_stays (memory_back s);
  Alcotest.(check (option string)) "back on the table" None s.memory_facts_keeper;
  check_back "then the table leaves" Memory_leaves (memory_back s)

let () =
  Alcotest.run "tui_memory_back"
    [ ( "memory back"
      , [ Alcotest.test_case "table filter clears before leaving" `Quick
            test_table_filter_clears_before_leaving
        ; Alcotest.test_case "fact browser clears, then closes" `Quick
            test_fact_browser_clears_then_closes
        ] )
    ]
