(** Tests for {!Keeper_model_input_ledger} (RFC keeper-context-window-in-tokens
    §10.3).

    The ledger writes down what the provider counted for the atoms a request
    carried. These pin the arithmetic of the difference between two requests,
    what a missing usage does to it, and which changes restart the ledger
    rather than being attributed. *)

module Ledger = Masc.Keeper_model_input_ledger

open Alcotest

let prefix = "f-prefix"

let request ?(prefix_digest = prefix) ?(tail_bytes = 100) ~first_atom ~atom_count ()
  : Ledger.request
  =
  { prefix_digest; first_atom; atom_count; tail_bytes }
;;

let usage ?(cache_read_input_tokens = 0) input_tokens : Ledger.usage =
  { input_tokens; cache_read_input_tokens }
;;

let step ledger req u = Ledger.observe ledger req u

let block_tokens (t : Ledger.t) =
  List.map (fun (b : Ledger.block) -> b.block_first_atom, b.block_end_atom, b.tokens) t.blocks
;;

let blocks_testable = list (triple int int (option int))

let test_first_request_starts_with_one_unmeasured_block () =
  let o = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  check string "event" "started" (Ledger.event_to_string o.event);
  check (option int) "total is the usage" (Some 1_000) o.ledger.total_tokens;
  check blocks_testable "one block of unknown size" [ 0, 10, None ] (block_tokens o.ledger);
  check int "every carried atom is unmeasured" 10 (Ledger.unmeasured_atoms o.ledger);
  check int "nothing known" 0 (Ledger.known_tokens o.ledger)
;;

let test_appended_atoms_are_measured_by_the_difference () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  check string "event" "appended_measured" (Ledger.event_to_string o2.event);
  check (option int) "delta" (Some 300) o2.delta_tokens;
  check blocks_testable "the new block carries the delta"
    [ 0, 10, None; 10, 12, Some 300 ]
    (block_tokens o2.ledger);
  check int "known tokens" 300 (Ledger.known_tokens o2.ledger);
  check (option int) "total moves to the new usage" (Some 1_300) o2.ledger.total_tokens;
  check (option int) "measured up to the new end" (Some 12) o2.ledger.measured_end_atom
;;

let test_tail_change_is_part_of_the_difference_and_reported () =
  let o1 =
    step None (request ~first_atom:0 ~atom_count:10 ~tail_bytes:100 ()) (Some (usage 1_000))
  in
  let o2 =
    step
      (Some o1.ledger)
      (request ~first_atom:0 ~atom_count:12 ~tail_bytes:160 ())
      (Some (usage 1_320))
  in
  check int "tail grew by 60 bytes" 60 o2.tail_delta_bytes;
  check (option int) "the block is charged the whole difference" (Some 320) o2.delta_tokens
;;

let test_usage_gap_measures_the_stretch_as_one_block () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 = step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) None in
  check string "event" "appended_unmeasured" (Ledger.event_to_string o2.event);
  check (option int) "no delta without usage" None o2.delta_tokens;
  check (option int) "total still the last measured" (Some 1_000) o2.ledger.total_tokens;
  check (option int) "measured end unchanged" (Some 10) o2.ledger.measured_end_atom;
  let o3 =
    step (Some o2.ledger) (request ~first_atom:0 ~atom_count:14 ()) (Some (usage 1_500))
  in
  check (option int) "delta spans both requests" (Some 500) o3.delta_tokens;
  check blocks_testable "the two unmeasured blocks merge into one"
    [ 0, 10, None; 10, 14, Some 500 ]
    (block_tokens o3.ledger)
;;

let test_repeated_range_records_only_the_tail_change () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_010))
  in
  check string "event" "repeated" (Ledger.event_to_string o2.event);
  check (option int) "delta is the tail alone" (Some 10) o2.delta_tokens;
  check blocks_testable "no block added" [ 0, 10, None ] (block_tokens o2.ledger);
  check (option int) "total follows the usage" (Some 1_010) o2.ledger.total_tokens
;;

(* The cold-start block leaves whole. What stayed keeps its counts; the total
   is unknown until the provider counts the new request. *)
let test_front_move_over_the_unmeasured_block_keeps_the_rest () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  let o3 =
    step (Some o2.ledger) (request ~first_atom:0 ~atom_count:14 ()) (Some (usage 1_500))
  in
  let o4 = step (Some o3.ledger) (request ~first_atom:10 ~atom_count:16 ()) None in
  check string "event" "front_moved_unmeasured" (Ledger.event_to_string o4.event);
  check blocks_testable "measured blocks survive, the new one is unmeasured"
    [ 10, 12, Some 300; 12, 14, Some 200; 14, 16, None ]
    (block_tokens o4.ledger);
  check (option int) "total unknown after an unmeasured eviction" None o4.ledger.total_tokens;
  let o5 =
    step (Some o4.ledger) (request ~first_atom:10 ~atom_count:18 ()) (Some (usage 900))
  in
  check (option int) "no delta against an unknown total" None o5.delta_tokens;
  check (option int) "the usage becomes the total" (Some 900) o5.ledger.total_tokens;
  check (option int) "measured up to this request" (Some 18) o5.ledger.measured_end_atom;
  let o6 =
    step (Some o5.ledger) (request ~first_atom:10 ~atom_count:20 ()) (Some (usage 1_050))
  in
  check (option int) "measurement resumes" (Some 150) o6.delta_tokens
;;

let test_front_move_over_measured_blocks_subtracts_them () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  let o3 =
    step (Some o2.ledger) (request ~first_atom:0 ~atom_count:14 ()) (Some (usage 1_500))
  in
  (* Evict the cold-start block first (unknown), then measure two blocks on a
     known total, then evict one of those. *)
  let o4 =
    step (Some o3.ledger) (request ~first_atom:10 ~atom_count:14 ()) (Some (usage 700))
  in
  let o5 =
    step (Some o4.ledger) (request ~first_atom:10 ~atom_count:16 ()) (Some (usage 900))
  in
  let o6 =
    step (Some o5.ledger) (request ~first_atom:10 ~atom_count:18 ()) (Some (usage 1_150))
  in
  check blocks_testable "two blocks measured on the known total"
    [ 10, 12, Some 300; 12, 14, Some 200; 14, 16, Some 200; 16, 18, Some 250 ]
    (block_tokens o6.ledger);
  let o7 =
    step (Some o6.ledger) (request ~first_atom:14 ~atom_count:20 ()) (Some (usage 800))
  in
  (match o7.event with
   | Ledger.Front_moved { evicted_atoms; evicted_tokens } ->
     check int "four atoms left" 4 evicted_atoms;
     check (option int) "their tokens were known" (Some 500) evicted_tokens
   | other -> failf "expected front_moved_measured, got %s" (Ledger.event_to_string other));
  check (option int) "delta corrected for the eviction: 800 - (1150 - 500)"
    (Some 150)
    o7.delta_tokens;
  check blocks_testable "kept blocks intact, new block measured"
    [ 14, 16, Some 200; 16, 18, Some 250; 18, 20, Some 150 ]
    (block_tokens o7.ledger)
;;

let test_front_inside_a_block_restarts () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  let o3 =
    step (Some o2.ledger) (request ~first_atom:11 ~atom_count:13 ()) (Some (usage 400))
  in
  check string "event" "front_cut_through_block" (Ledger.event_to_string o3.event);
  check blocks_testable "restarted from the request" [ 11, 13, None ] (block_tokens o3.ledger);
  check (option int) "total is the new usage" (Some 400) o3.ledger.total_tokens
;;

let test_prefix_change_restarts () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step
      (Some o1.ledger)
      (request ~prefix_digest:"other" ~first_atom:0 ~atom_count:12 ())
      (Some (usage 1_400))
  in
  check string "event" "prefix_changed" (Ledger.event_to_string o2.event);
  check string "the ledger carries the new prefix" "other" o2.ledger.prefix_digest;
  check blocks_testable "restarted" [ 0, 12, None ] (block_tokens o2.ledger)
;;

let test_shrunk_history_restarts () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:3 ()) (Some (usage 300))
  in
  check string "event" "history_reset" (Ledger.event_to_string o2.event);
  check blocks_testable "restarted" [ 0, 3, None ] (block_tokens o2.ledger)
;;

let test_json_reports_counts_not_the_block_list () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  let json = Ledger.observation_to_json o2 in
  let open Yojson.Safe.Util in
  check string "event" "appended_measured" (json |> member "event" |> to_string);
  check int "delta" 300 (json |> member "delta_tokens" |> to_int);
  let ledger = json |> member "ledger" in
  check int "blocks counted" 2 (ledger |> member "blocks" |> to_int);
  check int "measured blocks counted" 1 (ledger |> member "measured_blocks" |> to_int);
  check int "unmeasured atoms" 10 (ledger |> member "unmeasured_atoms" |> to_int);
  check int "known tokens" 300 (ledger |> member "known_tokens" |> to_int)
;;

(* Four measured blocks on a known total, as the measured-eviction test
   builds them: [10,12) 300, [12,14) 200, [14,16) 200, [16,18) 250, total
   1150 measured up to 18. *)
let four_measured_blocks () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  let o3 =
    step (Some o2.ledger) (request ~first_atom:0 ~atom_count:14 ()) (Some (usage 1_500))
  in
  let o4 =
    step (Some o3.ledger) (request ~first_atom:10 ~atom_count:14 ()) (Some (usage 700))
  in
  let o5 =
    step (Some o4.ledger) (request ~first_atom:10 ~atom_count:16 ()) (Some (usage 900))
  in
  let o6 =
    step (Some o5.ledger) (request ~first_atom:10 ~atom_count:18 ()) (Some (usage 1_150))
  in
  o6.ledger
;;

(* One large tool result can push the front past everything that was
   carried. The new block then starts at the front, and the ledger keeps
   attributing on the next request instead of restarting. *)
let test_front_past_the_carried_range_starts_the_block_at_the_front () =
  let t = four_measured_blocks () in
  let o7 = step (Some t) (request ~first_atom:20 ~atom_count:24 ()) (Some (usage 700)) in
  check (option int) "delta: 700 - (1150 - 950)" (Some 500) o7.delta_tokens;
  check blocks_testable "the block covers the carried atoms only"
    [ 20, 24, Some 500 ]
    (block_tokens o7.ledger);
  check int "nothing unmeasured" 0 (Ledger.unmeasured_atoms o7.ledger);
  let o8 =
    step (Some o7.ledger) (request ~first_atom:20 ~atom_count:26 ()) (Some (usage 800))
  in
  check string "no restart on the next request" "appended_measured"
    (Ledger.event_to_string o8.event);
  check blocks_testable "measurement continues"
    [ 20, 24, Some 500; 24, 26, Some 100 ]
    (block_tokens o8.ledger)
;;

let test_known_eviction_without_usage_then_usage () =
  let t = four_measured_blocks () in
  let o7 = step (Some t) (request ~first_atom:12 ~atom_count:20 ()) None in
  (match o7.event with
   | Ledger.Front_moved { evicted_atoms; evicted_tokens } ->
     check int "two atoms left" 2 evicted_atoms;
     check (option int) "their tokens were known" (Some 300) evicted_tokens
   | other -> failf "expected front_moved_measured, got %s" (Ledger.event_to_string other));
  check (option int) "total corrected without a new usage" (Some 850) o7.ledger.total_tokens;
  check (option int) "measured end unchanged" (Some 18) o7.ledger.measured_end_atom;
  let o8 =
    step (Some o7.ledger) (request ~first_atom:12 ~atom_count:22 ()) (Some (usage 1_000))
  in
  check (option int) "delta against the corrected total" (Some 150) o8.delta_tokens;
  check blocks_testable "the usage-less stretch and the new atoms measure as one block"
    [ 12, 14, Some 200; 14, 16, Some 200; 16, 18, Some 250; 18, 22, Some 150 ]
    (block_tokens o8.ledger)
;;

(* The request after a newest-atom-only one widens the front toward older
   atoms. That is a restart, named for what it is. *)
let test_front_widening_restarts () =
  let o1 = step None (request ~first_atom:9 ~atom_count:10 ()) (Some (usage 100)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  check string "event" "front_widened" (Ledger.event_to_string o2.event);
  check blocks_testable "restarted" [ 0, 12, None ] (block_tokens o2.ledger);
  check (option int) "total is the new usage" (Some 1_300) o2.ledger.total_tokens
;;

let test_repeated_range_without_usage_changes_nothing () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 = step (Some o1.ledger) (request ~first_atom:0 ~atom_count:10 ()) None in
  check string "event" "repeated" (Ledger.event_to_string o2.event);
  check (option int) "total kept" (Some 1_000) o2.ledger.total_tokens;
  check (option int) "measured end kept" (Some 10) o2.ledger.measured_end_atom;
  check blocks_testable "blocks kept" [ 0, 10, None ] (block_tokens o2.ledger)
;;

(* A tail that shrank by more than the new atoms added makes the difference
   negative. It is reported; no block is written. *)
let test_negative_difference_is_reported_not_written () =
  let o1 =
    step None (request ~first_atom:0 ~atom_count:10 ~tail_bytes:2_000 ()) (Some (usage 1_000))
  in
  let o2 =
    step
      (Some o1.ledger)
      (request ~first_atom:0 ~atom_count:12 ~tail_bytes:100 ())
      (Some (usage 900))
  in
  check string "event" "appended_unmeasured" (Ledger.event_to_string o2.event);
  check (option int) "delta reported" (Some (-100)) o2.delta_tokens;
  check int "tail shrank" (-1_900) o2.tail_delta_bytes;
  check blocks_testable "the new block stays unmeasured"
    [ 0, 10, None; 10, 12, None ]
    (block_tokens o2.ledger);
  check (option int) "total follows the usage" (Some 900) o2.ledger.total_tokens
;;

let test_zero_input_tokens_is_not_a_usage () =
  check (option int) "zero is nothing" None
    (Option.map
       (fun (u : Ledger.usage) -> u.input_tokens)
       (Ledger.usage_of_counts ~input_tokens:0 ~cache_read_input_tokens:0));
  check (option int) "positive is a usage" (Some 5)
    (Option.map
       (fun (u : Ledger.usage) -> u.input_tokens)
       (Ledger.usage_of_counts ~input_tokens:5 ~cache_read_input_tokens:0))
;;

let test_prefix_digest_is_stable_and_separates_prompts () =
  let a = Ledger.prefix_digest ~system_prompt:"one" ~tools:[] in
  let a' = Ledger.prefix_digest ~system_prompt:"one" ~tools:[] in
  let b = Ledger.prefix_digest ~system_prompt:"two" ~tools:[] in
  check string "same input, same digest" a a';
  check bool "different prompt, different digest" true (a <> b);
  check int "sha256 hex" 64 (String.length a)
;;

let test_move_front_over_measured_blocks_adjusts_the_total () =
  let t = four_measured_blocks () in
  let moved = Ledger.move_front t ~first_atom:14 in
  check blocks_testable "two blocks left"
    [ 14, 16, Some 200; 16, 18, Some 250 ]
    (block_tokens moved);
  check (option int) "total less the evicted 500" (Some 650) moved.total_tokens;
  check (option int) "measured end kept" (Some 18) moved.measured_end_atom;
  check int "front recorded" 14 moved.last.first_atom;
  let o = step (Some moved) (request ~first_atom:14 ~atom_count:20 ()) (Some (usage 800)) in
  check string "the next request reads an unchanged front" "appended_measured"
    (Ledger.event_to_string o.event);
  check (option int) "delta against the adjusted total" (Some 150) o.delta_tokens
;;

let test_move_front_over_the_cold_block_blanks_the_total () =
  let o1 = step None (request ~first_atom:0 ~atom_count:10 ()) (Some (usage 1_000)) in
  let o2 =
    step (Some o1.ledger) (request ~first_atom:0 ~atom_count:12 ()) (Some (usage 1_300))
  in
  let moved = Ledger.move_front o2.ledger ~first_atom:10 in
  check blocks_testable "the measured block stays" [ 10, 12, Some 300 ] (block_tokens moved);
  check (option int) "total unknown" None moved.total_tokens;
  check (option int) "measured end unknown" None moved.measured_end_atom
;;

let test_move_front_that_does_not_advance_changes_nothing () =
  let t = four_measured_blocks () in
  check bool "same front, same ledger" true (Ledger.move_front t ~first_atom:10 == t);
  check bool "a front behind the current one changes nothing" true
    (Ledger.move_front t ~first_atom:3 == t)
;;

let test_move_front_inside_a_block_restarts_the_blocks () =
  let t = four_measured_blocks () in
  let moved = Ledger.move_front t ~first_atom:13 in
  check blocks_testable "one unknown block from the new front" [ 13, 18, None ] (block_tokens moved);
  check (option int) "total unknown" None moved.total_tokens
;;

let test_table_move_front_moves_the_pairs_ledger () =
  Ledger.Table.For_testing.reset ();
  let keeper_name = "alpha" and runtime_id = "r" and session_id = "trace-1" in
  (* No ledger yet: nothing to move, nothing written. *)
  Ledger.Table.move_front ~keeper_name ~runtime_id ~session_id ~first_atom:5;
  check bool "no ledger appears from a move" true
    (Option.is_none (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id));
  let _ =
    Ledger.Table.observe ~keeper_name ~runtime_id ~session_id
      ~request:(request ~first_atom:0 ~atom_count:10 ()) ~usage:(Some (usage 1_000))
  in
  let _ =
    Ledger.Table.observe ~keeper_name ~runtime_id ~session_id
      ~request:(request ~first_atom:0 ~atom_count:14 ()) ~usage:(Some (usage 1_400))
  in
  (* Another session of the same keeper and runtime is another history. *)
  check bool "a recovery session reads no front from the keeper's turns" true
    (Option.is_none (Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id:"recovery-1"));
  Ledger.Table.move_front ~keeper_name ~runtime_id ~session_id ~first_atom:10;
  match Ledger.Table.lookup ~keeper_name ~runtime_id ~session_id with
  | None -> fail "the ledger stays"
  | Some t ->
    check int "the next request composes from the new front" 10 t.last.first_atom;
    check (option int) "the cold block's size was unknown, so the total is too until the next usage"
      None t.total_tokens;
    check int "the measured block stays known" 400 (Ledger.known_tokens t);
    Ledger.Table.For_testing.reset ()
;;

let () =
  run
    "keeper_model_input_ledger"
    [ ( "difference"
      , [ test_case "first request" `Quick test_first_request_starts_with_one_unmeasured_block
        ; test_case "appended atoms" `Quick test_appended_atoms_are_measured_by_the_difference
        ; test_case "tail change" `Quick test_tail_change_is_part_of_the_difference_and_reported
        ; test_case "usage gap" `Quick test_usage_gap_measures_the_stretch_as_one_block
        ; test_case "repeated range" `Quick test_repeated_range_records_only_the_tail_change
        ; test_case "repeated without usage" `Quick
            test_repeated_range_without_usage_changes_nothing
        ; test_case "negative difference" `Quick
            test_negative_difference_is_reported_not_written
        ] )
    ; ( "front"
      , [ test_case "unmeasured block leaves" `Quick
            test_front_move_over_the_unmeasured_block_keeps_the_rest
        ; test_case "measured blocks leave" `Quick
            test_front_move_over_measured_blocks_subtracts_them
        ; test_case "cut inside a block" `Quick test_front_inside_a_block_restarts
        ; test_case "front past the carried range" `Quick
            test_front_past_the_carried_range_starts_the_block_at_the_front
        ; test_case "known eviction without usage" `Quick
            test_known_eviction_without_usage_then_usage
        ; test_case "front widening" `Quick test_front_widening_restarts
        ] )
    ; ( "restart"
      , [ test_case "prefix change" `Quick test_prefix_change_restarts
        ; test_case "shrunk history" `Quick test_shrunk_history_restarts
        ] )
    ; "json", [ test_case "counts only" `Quick test_json_reports_counts_not_the_block_list ]
    ; ( "inputs"
      , [ test_case "zero usage" `Quick test_zero_input_tokens_is_not_a_usage
        ; test_case "prefix digest" `Quick test_prefix_digest_is_stable_and_separates_prompts
        ] )
    ; ( "move_front"
      , [ test_case "over measured blocks" `Quick test_move_front_over_measured_blocks_adjusts_the_total
        ; test_case "over the cold block" `Quick test_move_front_over_the_cold_block_blanks_the_total
        ; test_case "not advancing" `Quick test_move_front_that_does_not_advance_changes_nothing
        ; test_case "inside a block" `Quick test_move_front_inside_a_block_restarts_the_blocks
        ; test_case "through the table" `Quick test_table_move_front_moves_the_pairs_ledger
        ] )
    ]
;;
