open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode

let make_fact ?(category = "general") ?(origin = "chat") ?(first = 100.0)
    ?(last = 200.0) ?(events = Decode.no_memory_fact_events) ~claim id : Decode.memory_fact =
  { mf_claim = claim
  ; mf_category = category
  ; mf_origin = origin
  ; mf_first_seen = first
  ; mf_last_seen = last
  ; mf_memory_id = id
  ; mf_events = events
  }

let used ?(retrieved = 0) ?(days = 0) ?last ?(cited = 0) ?(revised_from = []) () :
  Decode.memory_fact_events =
  { mfe_retrieved_count = retrieved
  ; mfe_retrieved_distinct_days = days
  ; mfe_last_retrieved_at = last
  ; mfe_cited_count = cited
  ; mfe_revised_from = revised_from
  }

let make_source_fact ~path ~claim sha : Decode.memory_source_fact =
  { msf_claim = claim
  ; msf_first_seen = 150.0
  ; msf_path = path
  ; msf_sha256 = sha
  }

let make_invalidation ~path ~reason ts : Decode.memory_invalidation =
  { mi_source_path = path
  ; mi_invalidated_at = ts
  ; mi_reason = reason
  }

let make_snapshot ~ordinary_facts ~source_facts ~invalidations =
  { Decode.mfs_keeper = "test_keeper"
  ; mfs_ordinary =
      Decode.Memory_store_present
        { mos_revision = 1
        ; mos_updated_at = 300.0
        ; mos_facts = ordinary_facts
        }
  ; mfs_source =
      Decode.Memory_store_present
        { mss_revision = 1
        ; mss_updated_at = 300.0
        ; mss_facts = source_facts
        ; mss_invalidations = invalidations
        }
  }

let category_filter_testable =
  let pp fmt = function
    | Types.Category_all -> Format.pp_print_string fmt "Category_all"
    | Types.Category_ordinary s -> Format.fprintf fmt "Category_ordinary %S" s
    | Types.Category_source -> Format.pp_print_string fmt "Category_source"
    | Types.Category_dropped -> Format.pp_print_string fmt "Category_dropped"
  in
  testable pp ( = )
;;

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
;;

let test_category_navigation () =
  let state = make_state () in
  let f1 = make_fact ~category:"rule" ~claim:"No local dune" "1" in
  let f2 = make_fact ~category:"persona" ~claim:"Voice is Roger" "2" in
  let f3 = make_fact ~category:"rule" ~claim:"Always test" "3" in
  let sf = make_source_fact ~path:"config.toml" ~claim:"Config bound" "sha1" in
  let inv = make_invalidation ~path:"docs.md" ~reason:"File removed" 250.0 in
  let snap =
    make_snapshot
      ~ordinary_facts:[ f1; f2; f3 ]
      ~source_facts:[ sf ]
      ~invalidations:[ inv ]
  in
  state.memory_facts <- Some snap;
  let cats = Types.memory_fact_categories state in
  check (list category_filter_testable) "categories list contains ordinary, source, and dropped"
    [ Types.Category_ordinary "persona"
    ; Types.Category_ordinary "rule"
    ; Types.Category_source
    ; Types.Category_dropped
    ] cats;
  (* Test cycling forward *)
  let c1 = Types.next_memory_category Types.Category_all cats in
  check category_filter_testable "first category" (Types.Category_ordinary "persona") c1;
  let c2 = Types.next_memory_category c1 cats in
  check category_filter_testable "second category" (Types.Category_ordinary "rule") c2;
  let c3 = Types.next_memory_category c2 cats in
  check category_filter_testable "third category" Types.Category_source c3;
  let c4 = Types.next_memory_category c3 cats in
  check category_filter_testable "fourth category" Types.Category_dropped c4;
  let c5 = Types.next_memory_category c4 cats in
  check category_filter_testable "wraps back to All" Types.Category_all c5;
  (* Test cycling backward *)
  let p1 = Types.prev_memory_category Types.Category_all cats in
  check category_filter_testable "last category from All" Types.Category_dropped p1;
  let p2 = Types.prev_memory_category p1 cats in
  check category_filter_testable "backward from dropped" Types.Category_source p2;
  let p3 = Types.prev_memory_category (Types.Category_ordinary "persona") cats in
  check category_filter_testable "backward from first wraps to All" Types.Category_all p3
;;

let test_category_filtering_isolation () =
  let state = make_state () in
  let f_ord_source = make_fact ~category:"source" ~claim:"Ordinary fact named source" "1" in
  let f_ord_other = make_fact ~category:"rule" ~claim:"Ordinary rule" "2" in
  let sf = make_source_fact ~path:"src.ml" ~claim:"Source file fact" "sha" in
  let inv = make_invalidation ~path:"inv.ml" ~reason:"File gone" 100.0 in
  state.memory_facts <-
    Some (make_snapshot
      ~ordinary_facts:[ f_ord_source; f_ord_other ]
      ~source_facts:[ sf ]
      ~invalidations:[ inv ]);
  (* Category_all -> 4 rows *)
  state.memory_facts_category <- Types.Category_all;
  check int "all rows" 4 (List.length (Types.memory_fact_rows state));
  (* Category_ordinary "source" -> only f_ord_source *)
  state.memory_facts_category <- Types.Category_ordinary "source";
  let rows_ord_src = Types.memory_fact_rows state in
  check int "only ordinary fact named source" 1 (List.length rows_ord_src);
  (match rows_ord_src with
   | [ Types.Memory_row_fact f ] -> check string "claim matches" "Ordinary fact named source" f.mf_claim
   | _ -> fail "expected ordinary fact");
  (* Category_source -> only source file fact sf *)
  state.memory_facts_category <- Types.Category_source;
  let rows_src = Types.memory_fact_rows state in
  check int "only source fact" 1 (List.length rows_src);
  (match rows_src with
   | [ Types.Memory_row_source_fact f ] -> check string "claim matches" "Source file fact" f.msf_claim
   | _ -> fail "expected source-bound fact");
  (* Category_dropped -> only invalidation inv *)
  state.memory_facts_category <- Types.Category_dropped;
  let rows_drop = Types.memory_fact_rows state in
  check int "only dropped fact" 1 (List.length rows_drop);
  (match rows_drop with
   | [ Types.Memory_row_invalidation f ] -> check string "reason matches" "File gone" f.mi_reason
   | _ -> fail "expected invalidation")
;;

let test_sorting_orders () =
  let state = make_state () in
  let f_low = make_fact ~category:"rule" ~last:100.0 ~claim:"C_low" "1" in
  let f_high = make_fact ~category:"persona" ~last:50.0 ~claim:"A_high" "2" in
  let f_newest = make_fact ~category:"config" ~last:500.0 ~claim:"B_newest" "3" in
  state.memory_facts <-
    Some (make_snapshot ~ordinary_facts:[ f_low; f_high; f_newest ] ~source_facts:[] ~invalidations:[]);
  (* 1. Sort by Recency (newest last_seen first) *)
  state.memory_facts_sort <- Types.Sort_recency;
  let rows_recency = Types.memory_fact_rows state in
  let claims_recency =
    List.map (function Types.Memory_row_fact f -> f.mf_claim | _ -> "") rows_recency
  in
  check (list string) "recency sort" [ "B_newest"; "C_low"; "A_high" ] claims_recency;
  (* 2. Sort by Category (A-Z) *)
  state.memory_facts_sort <- Types.Sort_category;
  let rows_cat = Types.memory_fact_rows state in
  let cats_sorted =
    List.map (function Types.Memory_row_fact f -> f.mf_category | _ -> "") rows_cat
  in
  check (list string) "category sort" [ "config"; "persona"; "rule" ] cats_sorted;
  (* 3. Sort by Claim (A-Z) *)
  state.memory_facts_sort <- Types.Sort_claim;
  let rows_claim = Types.memory_fact_rows state in
  let claims_sorted =
    List.map (function Types.Memory_row_fact f -> f.mf_claim | _ -> "") rows_claim
  in
  check (list string) "claim sort" [ "A_high"; "B_newest"; "C_low" ] claims_sorted;
  (* 4. Cycle: recency -> last retrieved -> retrieved count -> category -> claim -> recency *)
  let labels_from start steps =
    let rec go order n acc =
      if n = 0 then List.rev acc
      else go (Types.next_memory_sort order) (n - 1) (Types.memory_sort_order_label order :: acc)
    in
    go start steps []
  in
  check (list string) "the cycle visits every order once and wraps"
    [ "Recency (Newest)"
    ; "Last retrieved (Newest)"
    ; "Retrieved (Most)"
    ; "Category (A-Z)"
    ; "Claim (A-Z)"
    ; "Recency (Newest)"
    ]
    (labels_from Types.Sort_recency 6)
;;

(* RFC-0418: the two use-based orders read the record. A fact never retrieved
   sorts after the retrieved ones, and source and dropped rows, which have no
   record, stay last in their own recency order. *)
let test_use_based_sorting () =
  let state = make_state () in
  let often = make_fact ~last:100.0 ~claim:"often" ~events:(used ~retrieved:5 ~days:3 ~last:1_000.0 ()) "1" in
  let latest = make_fact ~last:900.0 ~claim:"latest" ~events:(used ~retrieved:2 ~days:1 ~last:5_000.0 ()) "2" in
  let never = make_fact ~last:800.0 ~claim:"never" "3" in
  state.memory_facts <-
    Some (make_snapshot ~ordinary_facts:[ never; often; latest ]
            ~source_facts:[ make_source_fact ~path:"docs/x.md" ~claim:"bound" "sha" ]
            ~invalidations:[]);
  let claims rows =
    List.map
      (function
        | Types.Memory_row_fact f -> f.Decode.mf_claim
        | Types.Memory_row_source_fact f -> f.Decode.msf_claim
        | Types.Memory_row_invalidation f -> f.Decode.mi_reason)
      rows
  in
  state.memory_facts_sort <- Types.Sort_last_retrieved;
  check (list string) "last retrieved first, never-retrieved next, source last"
    [ "latest"; "often"; "never"; "bound" ]
    (claims (Types.memory_fact_rows state));
  state.memory_facts_sort <- Types.Sort_retrieved_count;
  check (list string) "most retrieved first, ties and zero by recency, source last"
    [ "often"; "latest"; "never"; "bound" ]
    (claims (Types.memory_fact_rows state))
;;

let test_search_filtering () =
  let state = make_state () in
  let f1 = make_fact ~category:"rule" ~claim:"Dune 로컬 빌드 금지" "1" in
  let f2 = make_fact ~category:"persona" ~claim:"Roger 음성 모델" "2" in
  let f3 = make_fact ~category:"config" ~claim:"CI Dune 검사 필수" "3" in
  state.memory_facts <-
    Some (make_snapshot ~ordinary_facts:[ f1; f2; f3 ] ~source_facts:[] ~invalidations:[]);
  (* No query -> returns all 3 *)
  check int "all rows without query" 3 (List.length (Types.memory_fact_rows state));
  (* Filter by 'dune' case-insensitively -> matches f1 and f3 *)
  state.search_last <- "dune";
  let matched = Types.memory_fact_rows state in
  check int "matches 'dune'" 2 (List.length matched);
  (* Filter by 'roger' -> matches f2 *)
  state.search_last <- "roger";
  let matched_roger = Types.memory_fact_rows state in
  check int "matches 'roger'" 1 (List.length matched_roger);
  (* Active search input empty query: Some "" does not fall back to search_last *)
  state.search <- Some "";
  check int "active empty search matches all" 3 (List.length (Types.memory_fact_rows state));
  state.search <- None;
  (* Non-matching query *)
  state.search_last <- "nonexistent";
  check int "no match" 0 (List.length (Types.memory_fact_rows state))
;;

let () =
  run "masc_tui_memory_facts_explorer"
    [ ( "navigation"
      , [ test_case "category navigation" `Quick test_category_navigation
        ; test_case "category filtering isolation" `Quick test_category_filtering_isolation
        ] )
    ; ( "sorting"
      , [ test_case "sorting orders" `Quick test_sorting_orders
        ; test_case "use-based sorting reads the record" `Quick test_use_based_sorting
        ] )
    ; ( "search"
      , [ test_case "search filtering" `Quick test_search_filtering ] )
    ]
;;
