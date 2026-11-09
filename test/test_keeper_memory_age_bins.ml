module Age_bins = Masc.Keeper_memory_age_bins

let now = 1_000_000_000.0
let hour = Masc_time_constants.hour
let day = Masc_time_constants.day

(* A fact first seen at 0 under a clock at [age]: the age is exact, with no
   rounding from subtracting it off a large clock. *)
let index_at age = Age_bins.index (Age_bins.classify ~now:age 0.0)

(* The four exact edges, written out here rather than read from the module. *)
let exact_edges =
  [ "1h", Age_bins.Hour, hour, 1
  ; "1d", Age_bins.Day, day, 9
  ; "7d", Age_bins.Week, Masc_time_constants.days_to_seconds 7, 17
  ; "30d", Age_bins.Month, Masc_time_constants.days_to_seconds 30, 23
  ]
;;

let test_an_age_on_an_edge_starts_the_next_bin () =
  Alcotest.(check int) "24 bins" 24 (List.length Age_bins.bins);
  Alcotest.(check (list int)) "the bins run newest first"
    (List.init 24 Fun.id) (List.map Age_bins.index Age_bins.bins);
  Alcotest.(check int) "a first_seen ahead of now is in the newest bin" 0
    (Age_bins.index (Age_bins.classify ~now (now +. 100.0)));
  Alcotest.(check int) "a fact seen now is in the newest bin" 0 (index_at 0.0);
  List.iter
    (fun (label, edge, age, bin) ->
      Alcotest.(check int) (label ^ " starts its bin") bin (Age_bins.index (Age_bins.edge_bin edge));
      Alcotest.(check int) ("an age of exactly " ^ label) bin (index_at age);
      Alcotest.(check int) ("one second under " ^ label) (bin - 1) (index_at (age -. 1.0)))
    exact_edges;
  Alcotest.(check int) "a year is in the oldest bin" 23
    (index_at (Masc_time_constants.days_to_seconds 365))
;;

(* Between two edges the bins start on equal log steps: the age halfway
   (on the log axis) through step j of a span is in the span's bin j. *)
let test_the_bins_between_two_edges_are_equal_log_steps () =
  let spans =
    [ "1h to 1d", hour, day, 1, 8
    ; "1d to 7d", day, 7.0 *. day, 9, 8
    ; "7d to 30d", 7.0 *. day, 30.0 *. day, 17, 6
    ]
  in
  List.iter
    (fun (label, low, high, first, steps) ->
      List.iter
        (fun step ->
          let age = low *. Float.pow (high /. low) ((float_of_int step +. 0.5) /. float_of_int steps) in
          Alcotest.(check int) (Printf.sprintf "%s, step %d" label step) (first + step) (index_at age))
        (List.init steps Fun.id))
    spans
;;

let test_the_edge_words_are_the_edges () =
  Alcotest.(check bool) "the edges, youngest first, in the units people read" true
    (List.map Age_bins.edge_span Age_bins.edges
     = Age_bins.[ Hours 1; Days 1; Days 7; Days 30 ])
;;

let test_the_bins_add_up_to_the_facts () =
  Alcotest.(check int) "no facts" 0 (Age_bins.total (Age_bins.of_first_seen ~now []));
  let timestamps =
    [ now +. 10.0
    ; now -. 300.0
    ; now -. (2.0 *. hour)
    ; now -. (10.0 *. hour)
    ; now -. (2.0 *. day)
    ; now -. (10.0 *. day)
    ; now -. (90.0 *. day)
    ]
  in
  let bins = Age_bins.of_first_seen ~now timestamps in
  Alcotest.(check int) "every fact is counted once" (List.length timestamps) (Age_bins.total bins);
  Alcotest.(check int) "two facts under an hour" 2
    (Age_bins.count bins (List.hd Age_bins.bins));
  Alcotest.(check int) "one fact at 30 days or older" 1
    (Age_bins.count bins (List.nth Age_bins.bins 23));
  Alcotest.(check int) "adding two ladders adds their facts" (2 * List.length timestamps)
    (Age_bins.total (Age_bins.add bins bins))
;;

let test_json_roundtrip () =
  let bins = Age_bins.of_first_seen ~now [ now; now -. (3.0 *. hour); now -. (40.0 *. day) ] in
  match Age_bins.of_json (Age_bins.to_json bins) with
  | Error err -> Alcotest.fail err
  | Ok decoded ->
    List.iter
      (fun bin ->
        Alcotest.(check int) (Printf.sprintf "bin %d" (Age_bins.index bin))
          (Age_bins.count bins bin) (Age_bins.count decoded bin))
      Age_bins.bins
;;

let counts n value = `List (List.init n (fun _ -> `Int value))

let test_json_rejects_every_other_shape () =
  List.iter
    (fun (label, json) ->
      Alcotest.(check bool) label true (Result.is_error (Age_bins.of_json json)))
    [ ( "the four-key object"
      , `Assoc [ "under_hour", `Int 1; "under_day", `Int 2; "under_week", `Int 3; "older", `Int 4 ] )
    ; "23 counts", counts 23 0
    ; "25 counts", counts 25 0
    ; "no counts", `List []
    ; "a negative count", `List (`Int (-1) :: List.init 23 (fun _ -> `Int 0))
    ; "a float count", `List (`Float 1.0 :: List.init 23 (fun _ -> `Int 0))
    ; "null", `Null
    ];
  Alcotest.(check bool) "24 zero counts" true (Result.is_ok (Age_bins.of_json (counts 24 0)))
;;

let () =
  Alcotest.run
    "keeper_memory_age_bins"
    [ ( "bins"
      , [ Alcotest.test_case "an age on an edge starts the next bin" `Quick
            test_an_age_on_an_edge_starts_the_next_bin
        ; Alcotest.test_case "the bins between two edges are equal log steps" `Quick
            test_the_bins_between_two_edges_are_equal_log_steps
        ; Alcotest.test_case "the edge words are the edges" `Quick test_the_edge_words_are_the_edges
        ; Alcotest.test_case "the bins add up to the facts" `Quick test_the_bins_add_up_to_the_facts
        ; Alcotest.test_case "json roundtrip" `Quick test_json_roundtrip
        ; Alcotest.test_case "json rejects every other shape" `Quick
            test_json_rejects_every_other_shape
        ] )
    ]
;;
