open Alcotest

module P = Alloc_profile
module T = Alloc_profile.For_testing

let keys sites = List.map (fun (site : P.site_totals) -> site.key) sites

let with_clean f =
  T.reset ();
  Fun.protect ~finally:T.reset f
;;

let test_tables_follow_the_block_lifecycle () =
  with_clean @@ fun () ->
  T.set_sampling_rate 0.01;
  let a1 = T.observe_alloc ~key:"a" ~n_samples:2 in
  let a2 = T.observe_alloc ~key:"a" ~n_samples:2 in
  let _a3 = T.observe_alloc ~key:"a" ~n_samples:2 in
  let b = T.observe_alloc ~key:"b" ~n_samples:5 in
  T.observe_promote b;
  T.observe_dealloc a1;
  T.observe_dealloc a2;
  let report = P.report ~top:10 in
  check (list string) "allocated: a (6) ahead of b (5)" [ "a"; "b" ] (keys report.allocated);
  check (list string) "live: b (5) ahead of a (2)" [ "b"; "a" ] (keys report.live);
  check (list string) "major: only b" [ "b" ] (keys report.major);
  check int "live samples" 7 report.live_samples;
  check int "allocated samples" 11 report.allocated_samples;
  check int "nothing allocated in the major heap directly" 0 report.direct_major_samples;
  (* 5 samples at one sample per hundred words estimate 500 words. *)
  check int "b live words" 500 (List.hd report.live).words;
  check int "major words" 500 report.major_words;
  check int "drained" 0 report.pending_events
;;

let test_direct_major_allocation_counts_as_major_not_promotion () =
  with_clean @@ fun () ->
  T.set_sampling_rate 0.1;
  let big = T.observe_alloc_in_major ~key:"big" ~n_samples:3 in
  let report = P.report ~top:5 in
  check int "major samples" 3 report.major_samples;
  check int "direct major samples" 3 report.direct_major_samples;
  check (list string) "live" [ "big" ] (keys report.live);
  T.observe_dealloc big;
  check int "freed" 0 (P.report ~top:5).live_samples
;;

let test_top_cuts_the_tables_not_the_totals () =
  with_clean @@ fun () ->
  T.set_sampling_rate 0.5;
  List.iter (fun key -> ignore (T.observe_alloc ~key ~n_samples:1)) [ "x"; "y"; "z" ];
  let report = P.report ~top:2 in
  check int "two rows" 2 (List.length report.allocated);
  check int "three samples counted" 3 report.allocated_samples;
  check int "six words estimated" 6 report.allocated_words;
  check int "three sites" 3 report.sites
;;

let test_no_rate_means_no_word_estimate () =
  with_clean @@ fun () ->
  ignore (T.observe_alloc ~key:"k" ~n_samples:3);
  let report = P.report ~top:5 in
  check int "samples still counted" 3 report.allocated_samples;
  check int "words are zero without a rate" 0 report.allocated_words;
  check bool "not sampling" false report.sampling
;;

let test_sites_past_the_bound_fold_into_one () =
  with_clean @@ fun () ->
  for index = 1 to P.max_sites + 5 do
    ignore (T.observe_alloc ~key:(Printf.sprintf "site-%d" index) ~n_samples:1)
  done;
  let report = P.report ~top:1 in
  check int "table bound plus the overflow site" (P.max_sites + 1) report.sites;
  check int "every sample counted" (P.max_sites + 5) report.allocated_samples;
  check (list string) "the overflow site is the largest" [ P.overflow_site_key ]
    (keys report.allocated)
;;

let test_callstack_key_is_bounded_text () =
  let key = P.key_of_callstack (Printexc.get_callstack 64) in
  let lines = List.filter (fun line -> line <> "") (String.split_on_char '\n' key) in
  check bool "non-empty" true (lines <> []);
  check bool "at most the frame bound" true (List.length lines <= P.callstack_frames)
;;

(* The scenario the callback rule exists for: with a real profile sampling
   at a high rate, [report] allocates while it holds the table lock, memprof
   callbacks run on this same thread at those allocations, and nothing may
   raise or be lost. *)
let test_report_under_a_live_profile_does_not_raise () =
  with_clean @@ fun () ->
  P.start ~sampling_rate:0.01;
  Fun.protect ~finally:P.stop @@ fun () ->
  let sink = ref [] in
  for _ = 1 to 20_000 do
    sink := Array.make 64 0 :: !sink
  done;
  let first = P.report ~top:5 in
  check bool "sampling" true first.sampling;
  check bool "samples were taken" true (first.allocated_samples > 0);
  sink := [];
  Gc.full_major ();
  (* Deallocation callbacks run at poll points after the collection; one
     report drains what has run, the next catches the stragglers. *)
  ignore (P.report ~top:5 : P.report);
  let second = P.report ~top:5 in
  check bool "frees were reported after the sink was dropped" true
    (second.live_samples < first.live_samples);
  check int "nothing dropped" 0 second.dropped_samples
;;

let test_wire_shape () =
  with_clean @@ fun () ->
  T.set_sampling_rate 0.1;
  ignore (T.observe_alloc ~key:"site\nframe2" ~n_samples:1);
  match P.report_to_yojson (P.report ~top:5) with
  | `Assoc fields ->
    List.iter
      (fun key -> check bool key true (List.mem_assoc key fields))
      [ "live"; "major"; "allocated"; "dropped_samples"; "pending_events"; "sites" ];
    check bool "rate" true (List.mem ("sampling_rate", `Float 0.1) fields)
  | _ -> fail "object"
;;

let () =
  run
    "alloc_profile"
    [ ( "tables"
      , [ test_case "lifecycle" `Quick test_tables_follow_the_block_lifecycle
        ; test_case "direct major" `Quick test_direct_major_allocation_counts_as_major_not_promotion
        ; test_case "top" `Quick test_top_cuts_the_tables_not_the_totals
        ; test_case "no rate" `Quick test_no_rate_means_no_word_estimate
        ; test_case "site bound" `Quick test_sites_past_the_bound_fold_into_one
        ; test_case "callstack key" `Quick test_callstack_key_is_bounded_text
        ; test_case "wire" `Quick test_wire_shape
        ] )
    ; "profile", [ test_case "report under sampling" `Quick test_report_under_a_live_profile_does_not_raise ]
    ]
;;
