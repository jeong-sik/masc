(* The decisions behind the memory age ladder: which bin is drawn where, when a
   bin draws nothing, when a ladder is unmeasured instead of zero, and how a
   fleet's Keepers add up. What the words and glyphs look like is not tested. *)

module Ladder = Masc_tui_keeper_age_ladder
module Bins = Masc.Keeper_memory_age_bins

let all_bins = [ Bins.Under_hour; Bins.Under_day; Bins.Under_week; Bins.Older ]

let bins ~hour ~day ~week ~older : Bins.t =
  { under_hour = hour; under_day = day; under_week = week; older }
;;

let count_of (b : Bins.t) = function
  | Bins.Under_hour -> b.under_hour
  | Bins.Under_day -> b.under_day
  | Bins.Under_week -> b.under_week
  | Bins.Older -> b.older
;;

let is_empty = function
  | Ladder.Empty -> true
  | Ladder.Bar _ -> false
;;

let make_keeper ~keeper_id age_bins : Masc.Tui_decode_memory_health.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
  ; mkh_updated_at = None
  ; mkh_facts = 10
  ; mkh_observed_facts = 8
  ; mkh_derived_facts = 2
  ; mkh_support_invalidations = 0
  ; mkh_snapshot_bytes = 1024
  ; mkh_added = 0
  ; mkh_removed = 0
  ; mkh_snapshot_present = true
  ; mkh_age_bins = age_bins
  ; mkh_context_cycle =
      { mcc_saved = None
      ; mcc_saved_unreadable = false
      ; mcc_read_position = None
      ; mcc_read_position_unreadable = false
      ; mcc_rewriting_through = None
      ; mcc_unread_snapshot = Ok []
      ; mcc_unread_memory = Ok []
      ; mcc_prepared = None
      ; mcc_synthesis = None
      }
  ; mkh_librarian =
      { mlh_state = None
      ; mlh_measured_at = None
      ; mlh_unread_atom_turns = None
      ; mlh_unread_official_turns = None
      ; mlh_continuity_unread_atoms = None
      ; mlh_last_success_at = None
      ; mlh_last_failure_kind = None
      ; mlh_stalled = None
      }
  ; mkh_librarian_failures = 0
  ; mkh_vision_ingest_errors = 0
  ; mkh_vision_ingest_error_reasons = []
  ; mkh_read_error = None
  ; mkh_source_revision = 1
  ; mkh_source_facts = 0
  ; mkh_source_invalidations = 0
  ; mkh_source_snapshot_bytes = 0
  ; mkh_source_snapshot_present = true
  ; mkh_source_read_error = None
  ; mkh_alerts = []
  }
;;

let test_every_bin_is_drawn_once () =
  Alcotest.(check int)
    "four bins are drawn" (List.length all_bins) (List.length Ladder.oldest_first);
  Alcotest.(check bool)
    "each bin appears exactly once"
    true
    (List.sort_uniq Stdlib.compare Ladder.oldest_first
     = List.sort_uniq Stdlib.compare all_bins);
  Alcotest.(check bool)
    "the oldest bin is on the left"
    true
    (List.nth_opt Ladder.oldest_first 0 = Some Bins.Older);
  Alcotest.(check bool)
    "the newest bin is on the right"
    true
    (List.nth_opt Ladder.oldest_first 3 = Some Bins.Under_hour)
;;

let test_edges_are_the_edges_the_server_counts_with () =
  let now = 1794050000.0 in
  let check_edge below above =
    match Ladder.edge_seconds below with
    | None -> Alcotest.fail "a bin that ends must name its edge"
    | Some edge ->
      Alcotest.(check bool)
        "one second younger than the edge is still in the bin"
        true
        (Bins.classify ~now (now -. edge +. 1.0) = below);
      Alcotest.(check bool)
        "exactly at the edge is in the next older bin"
        true
        (Bins.classify ~now (now -. edge) = above)
  in
  check_edge Bins.Under_hour Bins.Under_day;
  check_edge Bins.Under_day Bins.Under_week;
  check_edge Bins.Under_week Bins.Older;
  Alcotest.(check bool)
    "the oldest bin has no edge" true (Ladder.edge_seconds Bins.Older = None)
;;

let test_an_empty_bin_never_draws_a_bar () =
  List.iter
    (fun (label, b) ->
      let counts = List.map (count_of b) Ladder.oldest_first in
      let marks = Ladder.marks b in
      Alcotest.(check int) (label ^ ": one mark per bin") 4 (List.length marks);
      List.iter2
        (fun count mark ->
          Alcotest.(check bool)
            (label ^ ": a bin draws nothing exactly when it holds nothing")
            (count = 0)
            (is_empty mark))
        counts
        marks)
    [ "no facts", Bins.zero
    ; "one fact among many", bins ~hour:1 ~day:0 ~week:0 ~older:1000
    ; "every bin", bins ~hour:3 ~day:5 ~week:8 ~older:13
    ; "only the newest", bins ~hour:7 ~day:0 ~week:0 ~older:0
    ]
;;

let test_the_oldest_is_drawn_first () =
  let empties b = List.map is_empty (Ladder.marks b) in
  Alcotest.(check (list bool))
    "facts older than the last edge draw the leftmost mark"
    [ false; true; true; true ]
    (empties (bins ~hour:0 ~day:0 ~week:0 ~older:5));
  Alcotest.(check (list bool))
    "facts first seen in the last hour draw the rightmost mark"
    [ true; true; true; false ]
    (empties (bins ~hour:5 ~day:0 ~week:0 ~older:0))
;;

let test_unmeasured_is_not_zero () =
  Alcotest.(check bool)
    "the cell of a ladder the server did not measure differs from a measured empty one"
    true
    (Ladder.cell None <> Ladder.cell (Some Bins.zero));
  List.iter
    (fun ko ->
      Alcotest.(check bool)
        "a Keeper's clauses differ the same way, in both languages"
        true
        (Ladder.keeper_clauses ~ko None <> Ladder.keeper_clauses ~ko (Some Bins.zero)))
    [ true; false ]
;;

let test_the_cell_carries_no_tone () =
  List.iter
    (fun b ->
      Alcotest.(check bool)
        "the ladder is a count, not a state"
        true
        ((Ladder.cell b).Masc_tui_keeper_axis_cell.tone = Masc_tui_keeper_axis_cell.Quiet))
    [ None; Some Bins.zero; Some (bins ~hour:0 ~day:0 ~week:0 ~older:40) ]
;;

let test_the_fleet_adds_the_keepers_that_carry_a_ladder () =
  let a = bins ~hour:1 ~day:2 ~week:3 ~older:4 in
  let b = bins ~hour:10 ~day:20 ~week:30 ~older:40 in
  Alcotest.(check bool)
    "no rows at all is the zero ladder, measured"
    true
    (Ladder.fleet_of ~refused_rows:0 []
     = Ladder.Measured { bins = Bins.zero; unmeasured_keepers = 0 });
  Alcotest.(check bool)
    "Keeper rows without a ladder are not a zero ladder"
    true
    (Ladder.fleet_of
       ~refused_rows:0
       [ make_keeper ~keeper_id:"alpha" None; make_keeper ~keeper_id:"beta" None ]
     = Ladder.Nobody_measured { keepers = 2 });
  Alcotest.(check bool)
    "the measured Keepers add up and the others are counted"
    true
    (Ladder.fleet_of
       ~refused_rows:0
       [ make_keeper ~keeper_id:"alpha" (Some a)
       ; make_keeper ~keeper_id:"beta" None
       ; make_keeper ~keeper_id:"gamma" (Some b)
       ]
     = Ladder.Measured
         { bins = bins ~hour:11 ~day:22 ~week:33 ~older:44; unmeasured_keepers = 1 })
;;

(* The server's totals count a row this build refused, so a sum without it
   must say that a Keeper is missing. *)
let test_a_refused_row_is_a_keeper_without_a_ladder () =
  let a = bins ~hour:1 ~day:2 ~week:3 ~older:4 in
  Alcotest.(check bool)
    "rows that were all refused are not a zero ladder"
    true
    (Ladder.fleet_of ~refused_rows:2 [] = Ladder.Nobody_measured { keepers = 2 });
  Alcotest.(check bool)
    "a refused row is counted beside the Keepers that carry a ladder"
    true
    (Ladder.fleet_of ~refused_rows:1 [ make_keeper ~keeper_id:"alpha" (Some a) ]
     = Ladder.Measured { bins = a; unmeasured_keepers = 1 });
  Alcotest.(check bool)
    "a refused row and a Keeper without a ladder are counted together"
    true
    (Ladder.fleet_of ~refused_rows:1 [ make_keeper ~keeper_id:"alpha" None ]
     = Ladder.Nobody_measured { keepers = 2 })
;;

let () =
  Alcotest.run
    "tui_keeper_age_ladder"
    [ ( "age ladder"
      , [ Alcotest.test_case "every bin is drawn once" `Quick test_every_bin_is_drawn_once
        ; Alcotest.test_case
            "edges are the edges the server counts with"
            `Quick
            test_edges_are_the_edges_the_server_counts_with
        ; Alcotest.test_case
            "an empty bin never draws a bar"
            `Quick
            test_an_empty_bin_never_draws_a_bar
        ; Alcotest.test_case "the oldest is drawn first" `Quick test_the_oldest_is_drawn_first
        ; Alcotest.test_case "unmeasured is not zero" `Quick test_unmeasured_is_not_zero
        ; Alcotest.test_case "the cell carries no tone" `Quick test_the_cell_carries_no_tone
        ; Alcotest.test_case
            "the fleet adds the keepers that carry a ladder"
            `Quick
            test_the_fleet_adds_the_keepers_that_carry_a_ladder
        ; Alcotest.test_case
            "a refused row is a keeper without a ladder"
            `Quick
            test_a_refused_row_is_a_keeper_without_a_ladder
        ] )
    ]
