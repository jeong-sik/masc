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
  check (list string) "promoted: only b" [ "b" ] (keys report.promoted);
  check int "live samples" 7 report.live_samples;
  check int "allocated samples" 11 report.allocated_samples;
  (* 5 samples at one sample per hundred words estimate 500 words. *)
  check int "b live words" 500 (List.hd report.live).words;
  check int "promoted words" 500 report.promoted_words
;;

let test_top_cuts_the_tables_not_the_totals () =
  with_clean @@ fun () ->
  T.set_sampling_rate 0.5;
  List.iter
    (fun key -> ignore (T.observe_alloc ~key ~n_samples:1))
    [ "x"; "y"; "z" ];
  let report = P.report ~top:2 in
  check int "two rows" 2 (List.length report.allocated);
  check int "three samples counted" 3 report.allocated_samples;
  check int "six words estimated" 6 report.allocated_words
;;

let test_no_rate_means_no_word_estimate () =
  with_clean @@ fun () ->
  ignore (T.observe_alloc ~key:"k" ~n_samples:3);
  let report = P.report ~top:5 in
  check int "samples still counted" 3 report.allocated_samples;
  check int "words are zero without a rate" 0 report.allocated_words;
  check bool "not sampling" false report.sampling
;;

let test_wire_shape () =
  with_clean @@ fun () ->
  T.set_sampling_rate 0.1;
  ignore (T.observe_alloc ~key:"site\nframe2" ~n_samples:1);
  match P.report_to_yojson (P.report ~top:5) with
  | `Assoc fields ->
    check bool "live table" true (List.mem_assoc "live" fields);
    check bool "allocated table" true (List.mem_assoc "allocated" fields);
    check bool "promoted table" true (List.mem_assoc "promoted" fields);
    check bool "rate" true (List.mem ("sampling_rate", `Float 0.1) fields)
  | _ -> fail "object"
;;

let () =
  run
    "alloc_profile"
    [ ( "tables"
      , [ test_case "lifecycle" `Quick test_tables_follow_the_block_lifecycle
        ; test_case "top" `Quick test_top_cuts_the_tables_not_the_totals
        ; test_case "no rate" `Quick test_no_rate_means_no_word_estimate
        ; test_case "wire" `Quick test_wire_shape
        ] )
    ]
;;
