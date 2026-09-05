open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode

let make_fact ?(category = "general") ?(origin = "chat") ?(first = 100.0)
    ?(last = 200.0) ?(reinf = 1) ~claim id : Decode.memory_fact =
  { mf_claim = claim
  ; mf_category = category
  ; mf_origin = origin
  ; mf_first_seen = first
  ; mf_last_seen = last
  ; mf_reinforcement = reinf
  ; mf_memory_id = id
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

let test_category_navigation () =
  let state = Types.init_state () in
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
  check (list string) "categories list contains ordinary, source, and dropped"
    [ "persona"; "rule"; "source"; "dropped" ] cats;
  (* Test cycling forward *)
  let c1 = Types.next_memory_category None cats in
  check (option string) "first category" (Some "persona") c1;
  let c2 = Types.next_memory_category c1 cats in
  check (option string) "second category" (Some "rule") c2;
  let c3 = Types.next_memory_category c2 cats in
  check (option string) "third category" (Some "source") c3;
  let c4 = Types.next_memory_category c3 cats in
  check (option string) "fourth category" (Some "dropped") c4;
  let c5 = Types.next_memory_category c4 cats in
  check (option string) "wraps back to All" None c5;
  (* Test cycling backward *)
  let p1 = Types.prev_memory_category None cats in
  check (option string) "last category from All" (Some "dropped") p1;
  let p2 = Types.prev_memory_category p1 cats in
  check (option string) "backward from dropped" (Some "source") p2;
  let p3 = Types.prev_memory_category (Some "persona") cats in
  check (option string) "backward from first wraps to All" None p3
;;

let test_sorting_orders () =
  let state = Types.init_state () in
  let f_low_reinf = make_fact ~category:"rule" ~reinf:1 ~last:100.0 ~claim:"C_low" "1" in
  let f_high_reinf = make_fact ~category:"persona" ~reinf:15 ~last:50.0 ~claim:"A_high" "2" in
  let f_newest = make_fact ~category:"config" ~reinf:3 ~last:500.0 ~claim:"B_newest" "3" in
  state.memory_facts <-
    Some (make_snapshot ~ordinary_facts:[ f_low_reinf; f_high_reinf; f_newest ] ~source_facts:[] ~invalidations:[]);
  (* 1. Sort by Reinforcement (highest first) *)
  state.memory_facts_sort <- Types.Sort_reinforcement;
  let rows_reinf = Types.memory_fact_rows state in
  let claims_reinf =
    List.map (function Types.Memory_row_fact f -> f.mf_claim | _ -> "") rows_reinf
  in
  check (list string) "reinforcement sort" [ "A_high"; "B_newest"; "C_low" ] claims_reinf;
  (* 2. Sort by Recency (newest last_seen first) *)
  state.memory_facts_sort <- Types.Sort_recency;
  let rows_recency = Types.memory_fact_rows state in
  let claims_recency =
    List.map (function Types.Memory_row_fact f -> f.mf_claim | _ -> "") rows_recency
  in
  check (list string) "recency sort" [ "B_newest"; "C_low"; "A_high" ] claims_recency;
  (* 3. Sort by Category (A-Z) *)
  state.memory_facts_sort <- Types.Sort_category;
  let rows_cat = Types.memory_fact_rows state in
  let cats_sorted =
    List.map (function Types.Memory_row_fact f -> f.mf_category | _ -> "") rows_cat
  in
  check (list string) "category sort" [ "config"; "persona"; "rule" ] cats_sorted;
  (* 4. Sort by Claim (A-Z) *)
  state.memory_facts_sort <- Types.Sort_claim;
  let rows_claim = Types.memory_fact_rows state in
  let claims_sorted =
    List.map (function Types.Memory_row_fact f -> f.mf_claim | _ -> "") rows_claim
  in
  check (list string) "claim sort" [ "A_high"; "B_newest"; "C_low" ] claims_sorted;
  (* 5. Cycle sort order *)
  check string "order label reinforcement" "Reinforcement (\xc3\x97N)" (Types.memory_sort_order_label Types.Sort_reinforcement);
  let next = Types.next_memory_sort Types.Sort_reinforcement in
  check string "order label recency" "Recency (Newest)" (Types.memory_sort_order_label next)
;;

let test_search_filtering () =
  let state = Types.init_state () in
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
  (* Non-matching query *)
  state.search_last <- "nonexistent";
  check int "no match" 0 (List.length (Types.memory_fact_rows state))
;;

let () =
  run "masc_tui_memory_facts_explorer"
    [ ( "navigation"
      , [ test_case "category navigation" `Quick test_category_navigation ] )
    ; ( "sorting"
      , [ test_case "sorting orders" `Quick test_sorting_orders ] )
    ; ( "search"
      , [ test_case "search filtering" `Quick test_search_filtering ] )
    ]
;;
