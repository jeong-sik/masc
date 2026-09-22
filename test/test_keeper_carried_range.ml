(** Tests for {!Keeper_carried_range} (RFC keeper-context-window-in-tokens
    §10.5).

    The walk evicts from the front on the ledger's numbers alone. These pin
    where it stops, what it does at a block of unknown size, that the newest
    block never leaves, and how a provider refusal differs from the marks. *)

module Range = Masc.Keeper_carried_range
module Ledger = Masc.Keeper_model_input_ledger

open Alcotest

let marks ~high ~low : Runtime_schema.context_marks =
  { high_water_tokens = high; low_water_tokens = low }
;;

(* Atom [i] of the synthetic history opens with the message ["m<i>"]. *)
let opener i = Printf.sprintf "m%d" i

let block ~first ~end_ tokens : Ledger.block =
  { block_first_atom = first; block_end_atom = end_; block_first_digest = opener first; tokens }
;;

(* A ledger whose carried range starts at the first block and whose total is
   given. The request fields only need to be consistent with the blocks. *)
let ledger ?(total = None) (blocks : Ledger.block list) : Ledger.t =
  let first_atom =
    match blocks with
    | b :: _ -> b.block_first_atom
    | [] -> 0
  in
  let atom_count =
    match List.rev blocks with
    | b :: _ -> b.block_end_atom
    | [] -> 0
  in
  { prefix_digest = "f"
  ; total_tokens = total
  ; measured_end_atom = Option.map (fun _ -> atom_count) total
  ; measured_demote_before = Option.map (fun _ -> 0) total
  ; blocks
  ; last =
      { prefix_digest = "f"
      ; first_atom
      ; atom_count
      ; ends =
          (match blocks with
           | [] -> Ledger.No_atom_carried
           | _ :: _ ->
             Ledger.Carried_atoms
               { front_digest = opener first_atom; end_digest = opener (atom_count - 1) })
      ; tail_bytes = 0
      ; turn_context = false
      ; demote_before = 0
      }
  ; last_usage = None
  }
;;

let evicted = function
  | Range.Evicted e -> e.evicted_blocks, e.evicted_atoms, e.evicted_tokens, e.first_atom, e.projected_total
  | Range.Unchanged _ -> fail "expected an eviction"
;;

let unchanged_reason = function
  | Range.Unchanged reason -> reason
  | Range.Evicted _ -> fail "expected no eviction"
;;

let reason = testable (fun fmt r ->
  Format.pp_print_string fmt
    (match r with
     | Range.Total_unknown -> "total_unknown"
     | Range.Within_high_water -> "within_high_water"
     | Range.Nothing_evictable -> "nothing_evictable"
     | Range.Held_by_turn_floor -> "held_by_turn_floor"))
  ( = )
;;

let measured_four =
  [ block ~first:0 ~end_:10 (Some 300)
  ; block ~first:10 ~end_:20 (Some 250)
  ; block ~first:20 ~end_:30 (Some 200)
  ; block ~first:30 ~end_:40 (Some 150)
  ]
;;

let test_within_high_water_leaves_the_range () =
  let t = ledger ~total:(Some 900) measured_four in
  check reason "no eviction" Range.Within_high_water
    (unchanged_reason (Range.at_turn_boundary ~marks:(marks ~high:1_000 ~low:600) t))
;;

let test_unknown_total_cannot_be_judged () =
  let t = ledger measured_four in
  check reason "no total" Range.Total_unknown
    (unchanged_reason (Range.at_turn_boundary ~marks:(marks ~high:100 ~low:50) t))
;;

(* Total 1,000 (900 in blocks plus the prefix), low-water 500: the first two
   blocks take 550 off and the projected total lands at 450. *)
let test_walks_down_to_the_low_water_mark () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, atoms, tokens, first_atom, projected =
    evicted (Range.at_turn_boundary ~marks:(marks ~high:950 ~low:500) t)
  in
  check int "two blocks" 2 blocks;
  check int "twenty atoms" 20 atoms;
  check (option int) "their tokens" (Some 550) tokens;
  check int "front moves to the third block" 20 first_atom;
  check (option int) "projected total" (Some 450) projected;
  match Range.at_turn_boundary ~marks:(marks ~high:950 ~low:500) t with
  | Range.Evicted { front_digest; _ } ->
    check string "the moved front is named by the block it stopped at" (opener 20) front_digest
  | Range.Unchanged _ -> fail "expected an eviction"
;;

let test_never_evicts_the_newest_block () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, _, tokens, first_atom, projected =
    evicted (Range.at_turn_boundary ~marks:(marks ~high:950 ~low:10) t)
  in
  check int "three of four" 3 blocks;
  check (option int) "750 off" (Some 750) tokens;
  check int "the newest block stays" 30 first_atom;
  check (option int) "still above the mark, and that is reported" (Some 250) projected
;;

let test_unknown_block_leaves_whole_and_ends_the_walk () =
  let t =
    ledger
      ~total:(Some 1_000)
      [ block ~first:0 ~end_:10 (Some 300)
      ; block ~first:10 ~end_:25 None
      ; block ~first:25 ~end_:30 (Some 200)
      ; block ~first:30 ~end_:40 (Some 150)
      ]
  in
  let blocks, atoms, tokens, first_atom, projected =
    evicted (Range.at_turn_boundary ~marks:(marks ~high:950 ~low:100) t)
  in
  check int "measured then unknown" 2 blocks;
  check int "atoms of both" 25 atoms;
  check (option int) "tokens unknown" None tokens;
  check int "front after the unknown block" 25 first_atom;
  check (option int) "total unknown until the next usage" None projected
;;

let test_single_block_is_not_evictable () =
  let t = ledger ~total:(Some 5_000) [ block ~first:0 ~end_:10 (Some 4_000) ] in
  check reason "nothing to evict" Range.Nothing_evictable
    (unchanged_reason (Range.at_turn_boundary ~marks:(marks ~high:100 ~low:50) t));
  check reason "nor on a refusal" Range.Nothing_evictable
    (unchanged_reason (Range.after_overflow ~marks:None t))
;;

let test_unnamed_carried_range_is_not_evictable () =
  let observed = ledger ~total:(Some 1_000) measured_four in
  let t = { observed with last = { observed.last with ends = Ledger.No_atom_carried } } in
  let expected = Range.Unchanged Range.Nothing_evictable in
  check bool "decision stays unchanged" true
    (Range.at_turn_boundary ~marks:(marks ~high:950 ~low:500) t = expected);
  let applied, step = Range.apply_turn_boundary ~marks:(marks ~high:950 ~low:500) t in
  check bool "application preserves the ledger" true (applied = t);
  check bool "application preserves the decision" true (step = expected)
;;

let test_overflow_without_marks_takes_one_block () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, atoms, tokens, first_atom, projected = evicted (Range.after_overflow ~marks:None t) in
  check int "one block" 1 blocks;
  check int "its atoms" 10 atoms;
  check (option int) "its tokens" (Some 300) tokens;
  check int "front" 10 first_atom;
  check (option int) "projected" (Some 700) projected
;;

let test_overflow_with_marks_walks_even_below_the_high_water () =
  let t = ledger ~total:(Some 900) measured_four in
  let blocks, _, tokens, first_atom, projected =
    evicted (Range.after_overflow ~marks:(Some (marks ~high:1_000 ~low:400)) t)
  in
  check int "two blocks to reach 400" 2 blocks;
  check (option int) "550 off" (Some 550) tokens;
  check int "front" 20 first_atom;
  check (option int) "projected" (Some 350) projected
;;

let test_overflow_with_marks_but_unknown_total_takes_one_block () =
  let t = ledger measured_four in
  let blocks, _, tokens, first_atom, projected =
    evicted (Range.after_overflow ~marks:(Some (marks ~high:1_000 ~low:400)) t)
  in
  check int "one block" 1 blocks;
  check (option int) "its tokens were known" (Some 300) tokens;
  check int "front" 10 first_atom;
  check (option int) "nothing to project" None projected
;;

(* The shape every fresh ledger has: the cold-start block of unknown size in
   front of measured ones. The first walk takes only it. *)
let test_cold_start_block_first_leaves_alone_with_the_total_unknown () =
  let t =
    ledger
      ~total:(Some 1_000)
      [ block ~first:0 ~end_:10 None
      ; block ~first:10 ~end_:20 (Some 300)
      ; block ~first:20 ~end_:30 (Some 200)
      ]
  in
  let blocks, atoms, tokens, first_atom, projected =
    evicted (Range.at_turn_boundary ~marks:(marks ~high:900 ~low:100) t)
  in
  check int "just the cold block" 1 blocks;
  check int "its atoms" 10 atoms;
  check (option int) "size unknown" None tokens;
  check int "front after it" 10 first_atom;
  check (option int) "total unknown until the next usage" None projected
;;

let test_total_at_the_high_water_mark_is_within () =
  let t = ledger ~total:(Some 1_000) measured_four in
  check reason "equal is within" Range.Within_high_water
    (unchanged_reason (Range.at_turn_boundary ~marks:(marks ~high:1_000 ~low:500) t))
;;

let test_landing_exactly_on_the_low_water_mark_stops () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, _, _, _, projected =
    evicted (Range.at_turn_boundary ~marks:(marks ~high:950 ~low:450) t)
  in
  check int "two blocks bring it to 450" 2 blocks;
  check (option int) "exactly the mark" (Some 450) projected
;;

(* Inside a turn the walk is floored at the turn's first atom. The four
   blocks above with the turn starting at atom 20: the first two lie before
   the turn and leave (550 off, projected 450), the third is the turn's and
   stops the walk even though 450 is still above a low-water mark of 100. *)
let test_within_turn_evicts_only_the_blocks_before_the_turn () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, atoms, tokens, first_atom, projected =
    evicted (Range.within_turn ~marks:(marks ~high:950 ~low:100) ~turn_first_atom:20 t)
  in
  check int "the two blocks before the turn" 2 blocks;
  check int "twenty atoms" 20 atoms;
  check (option int) "their tokens" (Some 550) tokens;
  check int "the front stops at the turn's first atom" 20 first_atom;
  check (option int) "still above the low-water mark, and that is reported" (Some 450) projected
;;

(* A block that straddles the turn's first atom is not taken either: with
   the turn starting at atom 15, only the first block (0..10) leaves. *)
let test_within_turn_never_takes_a_block_that_reaches_into_the_turn () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, _, tokens, first_atom, projected =
    evicted (Range.within_turn ~marks:(marks ~high:950 ~low:100) ~turn_first_atom:15 t)
  in
  check int "one block" 1 blocks;
  check (option int) "300 off" (Some 300) tokens;
  check int "the front stops before the straddling block" 10 first_atom;
  check (option int) "projected" (Some 700) projected
;;

let test_within_turn_is_held_when_the_oldest_block_is_the_turns () =
  let t = ledger ~total:(Some 1_000) measured_four in
  check reason "held by the turn floor" Range.Held_by_turn_floor
    (unchanged_reason (Range.within_turn ~marks:(marks ~high:950 ~low:100) ~turn_first_atom:5 t))
;;

let test_within_turn_leaves_a_total_within_the_high_water_mark () =
  let t = ledger ~total:(Some 900) measured_four in
  check reason "within" Range.Within_high_water
    (unchanged_reason (Range.within_turn ~marks:(marks ~high:1_000 ~low:600) ~turn_first_atom:20 t))
;;

(* With every block before the turn, the in-turn walk is the turn-boundary
   walk: down to the low-water mark, the newest block kept. *)
let test_within_turn_walks_like_the_boundary_when_the_turn_is_newest () =
  let t = ledger ~total:(Some 1_000) measured_four in
  let blocks, _, _, first_atom, projected =
    evicted (Range.within_turn ~marks:(marks ~high:950 ~low:500) ~turn_first_atom:40 t)
  in
  check int "two blocks" 2 blocks;
  check int "front at the third block" 20 first_atom;
  check (option int) "under the low-water mark" (Some 450) projected
;;

let test_no_blocks_is_not_evictable () =
  let t = ledger ~total:(Some 1_000) [] in
  check reason "empty" Range.Nothing_evictable
    (unchanged_reason (Range.at_turn_boundary ~marks:(marks ~high:100 ~low:50) t))
;;

let test_overflow_always_takes_at_least_one_block () =
  (* Already at or below the low-water mark, yet refused: something else is
     large. One block goes anyway. *)
  let t = ledger ~total:(Some 300) measured_four in
  let blocks, _, _, _, _ =
    evicted (Range.after_overflow ~marks:(Some (marks ~high:1_000 ~low:400)) t)
  in
  check int "one block" 1 blocks
;;

let () =
  run
    "keeper_carried_range"
    [ ( "at_turn_boundary"
      , [ test_case "within high water" `Quick test_within_high_water_leaves_the_range
        ; test_case "unknown total" `Quick test_unknown_total_cannot_be_judged
        ; test_case "down to low water" `Quick test_walks_down_to_the_low_water_mark
        ; test_case "newest block stays" `Quick test_never_evicts_the_newest_block
        ; test_case "unknown block ends the walk" `Quick
            test_unknown_block_leaves_whole_and_ends_the_walk
        ; test_case "single block" `Quick test_single_block_is_not_evictable
        ; test_case "unnamed carried range" `Quick test_unnamed_carried_range_is_not_evictable
        ; test_case "cold block first" `Quick
            test_cold_start_block_first_leaves_alone_with_the_total_unknown
        ; test_case "total equal to high water" `Quick test_total_at_the_high_water_mark_is_within
        ; test_case "landing on low water" `Quick test_landing_exactly_on_the_low_water_mark_stops
        ; test_case "no blocks" `Quick test_no_blocks_is_not_evictable
        ] )
    ; ( "within a turn"
      , [ test_case "only the blocks before the turn" `Quick
            test_within_turn_evicts_only_the_blocks_before_the_turn
        ; test_case "a straddling block stays" `Quick
            test_within_turn_never_takes_a_block_that_reaches_into_the_turn
        ; test_case "held by the turn floor" `Quick
            test_within_turn_is_held_when_the_oldest_block_is_the_turns
        ; test_case "within high water" `Quick
            test_within_turn_leaves_a_total_within_the_high_water_mark
        ; test_case "turn is newest: boundary walk" `Quick
            test_within_turn_walks_like_the_boundary_when_the_turn_is_newest
        ] )
    ; ( "after_overflow"
      , [ test_case "no marks: one block" `Quick test_overflow_without_marks_takes_one_block
        ; test_case "marks: walk below high water" `Quick
            test_overflow_with_marks_walks_even_below_the_high_water
        ; test_case "marks, unknown total: one block" `Quick
            test_overflow_with_marks_but_unknown_total_takes_one_block
        ; test_case "at least one block" `Quick test_overflow_always_takes_at_least_one_block
        ] )
    ]
;;
