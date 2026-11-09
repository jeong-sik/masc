module Age_bins = Masc.Keeper_memory_age_bins

let now = 1_000_000_000.0
let hour = Masc_time_constants.hour
let day = Masc_time_constants.day

(* A fact first seen at 0 under a clock at [age]: the age is exact, with no
   rounding from subtracting it off a large clock. *)
let index_at age = Age_bins.index (Age_bins.classify ~now:age 0.0)

let test_the_ladder_edges () =
  Alcotest.(check int) "a first_seen ahead of now is in the newest bin" 0
    (Age_bins.index (Age_bins.classify ~now (now +. 100.0)));
  Alcotest.(check int) "a fact seen now is in the newest bin" 0 (index_at 0.0);
  Alcotest.(check int) "one second under an hour is in the newest bin" 0 (index_at (hour -. 1.0));
  Alcotest.(check int) "exactly one hour starts bin 1" 1 (index_at hour);
  Alcotest.(check int) "one second under 30 days is in bin 22" 22
    (index_at (Masc_time_constants.days_to_seconds 30 -. 1.0));
  Alcotest.(check int) "exactly 30 days starts the oldest bin" 23
    (index_at (Masc_time_constants.days_to_seconds 30));
  Alcotest.(check int) "a year is in the oldest bin" 23
    (index_at (Masc_time_constants.days_to_seconds 365))
;;

(* Each bin starts where the formula of RFC-0515 §2.4.5 says, and the edge
   [lower_edge] names is the one [classify] counts with. *)
let test_every_edge_starts_its_bin () =
  Alcotest.(check int) "24 bins" 24 (List.length Age_bins.bins);
  Alcotest.(check (list int)) "the bins run newest first"
    (List.init 24 Fun.id) (List.map Age_bins.index Age_bins.bins);
  let r = Float.log 720.0 /. 22.0 in
  List.iter
    (fun bin ->
      let k = Age_bins.index bin in
      let edge = Age_bins.lower_edge bin in
      if k = 0 then Alcotest.(check (float 0.0)) "bin 0 starts at age 0" 0.0 edge
      else begin
        Alcotest.(check (float 1e-6)) (Printf.sprintf "bin %d starts on its log step" k)
          (hour *. Float.exp (float_of_int (k - 1) *. r)) edge;
        Alcotest.(check int) (Printf.sprintf "the edge of bin %d is in bin %d" k k) k (index_at edge);
        Alcotest.(check int) (Printf.sprintf "one second under the edge of bin %d is in bin %d" k (k - 1))
          (k - 1) (index_at (edge -. 1.0))
      end)
    Age_bins.bins
;;

let test_the_tick_ages_land_on_their_nearest_edge () =
  List.iter
    (fun (label, age, expected) ->
      Alcotest.(check int) label expected (Age_bins.index (Age_bins.nearest_edge age)))
    [ "1h", hour, 1
    ; "6h", 6.0 *. hour, 7
    ; "1d", day, 12
    ; "7d", 7.0 *. day, 18
    ; "30d", 30.0 *. day, 23
    ; "under an hour", 60.0, 1
    ; "past 30 days", 400.0 *. day, 23
    ]
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
      , [ Alcotest.test_case "the ladder edges" `Quick test_the_ladder_edges
        ; Alcotest.test_case "every edge starts its bin" `Quick test_every_edge_starts_its_bin
        ; Alcotest.test_case "tick ages land on their nearest edge" `Quick
            test_the_tick_ages_land_on_their_nearest_edge
        ; Alcotest.test_case "the bins add up to the facts" `Quick test_the_bins_add_up_to_the_facts
        ; Alcotest.test_case "json roundtrip" `Quick test_json_roundtrip
        ; Alcotest.test_case "json rejects every other shape" `Quick
            test_json_rejects_every_other_shape
        ] )
    ]
;;
