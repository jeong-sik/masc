(* The decisions behind the memory age ladder: which bin is drawn where, when a
   bin draws nothing, when a ladder is unmeasured instead of zero, and how a
   fleet's Keepers add up. What the words and glyphs look like is not tested. *)

module Ladder = Masc_tui_keeper_age_ladder
module Bins = Masc.Keeper_memory_age_bins

(* A ladder from its 24 counts, newest bin first, as the server sends it. *)
let ladder counts =
  match Bins.of_json (`List (List.map (fun n -> `Int n) counts)) with
  | Ok bins -> bins
  | Error err -> Alcotest.fail err
;;

(* [newest] in the newest bin, [oldest] in the oldest, none between. *)
let ends ~newest ~oldest = ladder ((newest :: List.init 22 (fun _ -> 0)) @ [ oldest ])

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
    "24 bins are drawn" Bins.bin_count (List.length Ladder.oldest_first);
  Alcotest.(check (list int))
    "the oldest bin is on the left and the newest on the right"
    (List.rev (List.init Bins.bin_count Fun.id))
    (List.map Bins.index Ladder.oldest_first)
;;

let test_an_empty_bin_never_draws_a_bar () =
  List.iter
    (fun (label, b) ->
      let counts = List.map (Bins.count b) Ladder.oldest_first in
      let marks = Ladder.marks b in
      Alcotest.(check int) (label ^ ": one mark per bin") Bins.bin_count (List.length marks);
      List.iter2
        (fun count mark ->
          Alcotest.(check bool)
            (label ^ ": a bin draws nothing exactly when it holds nothing")
            (count = 0)
            (is_empty mark))
        counts
        marks)
    [ "no facts", Bins.zero
    ; "one fact among many", ends ~newest:1 ~oldest:1000
    ; "every bin", ladder (List.init Bins.bin_count (fun k -> k + 1))
    ; "only the newest", ends ~newest:7 ~oldest:0
    ]
;;

let test_the_oldest_is_drawn_first () =
  let drawn b = List.map (fun mark -> not (is_empty mark)) (Ladder.marks b) in
  let only k = List.init Bins.bin_count (fun i -> i = k) in
  Alcotest.(check (list bool))
    "facts 30 days or older draw the leftmost mark"
    (only 0)
    (drawn (ends ~newest:0 ~oldest:5));
  Alcotest.(check (list bool))
    "facts first seen in the last hour draw the rightmost mark"
    (only (Bins.bin_count - 1))
    (drawn (ends ~newest:5 ~oldest:0))
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
    [ None; Some Bins.zero; Some (ends ~newest:0 ~oldest:40) ]
;;

let test_the_fleet_adds_the_keepers_that_carry_a_ladder () =
  let a = ends ~newest:1 ~oldest:4 in
  let b = ends ~newest:10 ~oldest:40 in
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
         { bins = ends ~newest:11 ~oldest:44; unmeasured_keepers = 1 })
;;

(* The server's totals count a row this build refused, so a sum without it
   must say that a Keeper is missing. *)
let test_a_refused_row_is_a_keeper_without_a_ladder () =
  let a = ends ~newest:1 ~oldest:4 in
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
