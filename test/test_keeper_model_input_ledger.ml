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

let () =
  run
    "keeper_model_input_ledger"
    [ ( "difference"
      , [ test_case "first request" `Quick test_first_request_starts_with_one_unmeasured_block
        ; test_case "appended atoms" `Quick test_appended_atoms_are_measured_by_the_difference
        ; test_case "tail change" `Quick test_tail_change_is_part_of_the_difference_and_reported
        ; test_case "usage gap" `Quick test_usage_gap_measures_the_stretch_as_one_block
        ; test_case "repeated range" `Quick test_repeated_range_records_only_the_tail_change
        ] )
    ; ( "front"
      , [ test_case "unmeasured block leaves" `Quick
            test_front_move_over_the_unmeasured_block_keeps_the_rest
        ; test_case "measured blocks leave" `Quick
            test_front_move_over_measured_blocks_subtracts_them
        ; test_case "cut inside a block" `Quick test_front_inside_a_block_restarts
        ] )
    ; ( "restart"
      , [ test_case "prefix change" `Quick test_prefix_change_restarts
        ; test_case "shrunk history" `Quick test_shrunk_history_restarts
        ] )
    ; "json", [ test_case "counts only" `Quick test_json_reports_counts_not_the_block_list ]
    ]
;;
