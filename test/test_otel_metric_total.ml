(** [Otel_metric_store_core.metric_total] adds up the series filed under one
    name. [/health] reads three such totals per request, and the store holds a
    series for every label set of every metric, so a total reads only its own
    name's series.

    The store keeps its series behind a signature whose only insert files a
    series under both its key and its name. These cases pin what a total
    counts: every series of its name, whichever call created it, and no series
    of another name. *)

open Alcotest
module Store = Otel_metric_store_core

let near = float 1e-9

let test_a_total_sums_its_own_series_and_no_other () =
  let name = "masc_test_metric_total_sums_total" in
  Store.inc_counter name ~labels:[ "lane", "a" ] ~delta:2.0 ();
  Store.inc_counter name ~labels:[ "lane", "b" ] ~delta:3.0 ();
  Store.register_counter ~name ~help:name ~labels:[ "lane", "c" ] ();
  Store.inc_counter (name ^ "_other") ~delta:100.0 ();
  check near "every series of the name and no other" 5.0 (Store.metric_total name);
  Store.inc_counter name ~labels:[ "lane", "a" ] ~delta:4.0 ();
  check near "a later update to a series already held" 9.0 (Store.metric_total name)
;;

(* Every call that can create a series creates one here, and every series is
   then moved off its starting value, so a series left out of its name's total
   shows as a wrong sum. *)
let test_every_way_in_counts_toward_its_name () =
  let counter = "masc_test_metric_total_created_total" in
  ignore (Store.declare_counter counter : string);
  Store.register_counter ~name:counter ~help:counter ~labels:[ "via", "register" ] ();
  Store.inc_counter counter ();
  Store.inc_counter counter ~labels:[ "via", "register" ] ~delta:2.0 ();
  Store.inc_counter counter ~labels:[ "via", "inc" ] ~delta:4.0 ();
  check
    near
    "counter series from declare, register and inc"
    7.0
    (Store.metric_total counter);
  let gauge = "masc_test_metric_total_gauge" in
  ignore (Store.declare_gauge gauge : string);
  Store.register_gauge ~name:gauge ~help:gauge ~labels:[ "via", "register" ] ();
  Store.set_gauge gauge 0.25;
  Store.set_gauge gauge ~labels:[ "via", "register" ] 0.5;
  Store.set_gauge gauge ~labels:[ "via", "set" ] 1.5;
  Store.inc_gauge gauge ~labels:[ "via", "inc" ] ~delta:2.0 ();
  Store.dec_gauge gauge ~labels:[ "via", "dec" ] ~delta:0.5 ();
  check
    near
    "gauge series from declare, register, set, inc and dec"
    3.75
    (Store.metric_total gauge);
  let histogram = "masc_test_metric_total_seconds" in
  ignore (Store.declare_histogram histogram : string);
  Store.register_histogram ~name:histogram ~help:histogram ~labels:[ "via", "register" ] ();
  Store.register_histogram_buckets histogram [ 1.0; 10.0 ];
  Store.observe_histogram histogram 2.5;
  Store.observe_histogram histogram ~labels:[ "via", "register" ] 0.5;
  Store.observe_histogram histogram ~labels:[ "via", "observe" ] 5.0;
  check near "the histogram's sum series" 8.0 (Store.metric_total histogram);
  check
    near
    "its count series, under their own name"
    3.0
    (Store.metric_total (Store.histogram_count_name histogram));
  (* 2.5 and 5.0 land in le=10 and +Inf; 0.5 in le=1, le=10 and +Inf. *)
  check
    near
    "its bucket series, under their own name"
    7.0
    (Store.metric_total (histogram ^ "_bucket"))
;;

(* A write to a series that already exists changes that series. Inserting it
   again under the same key would leave two series behind one key, and the
   name's total would count both. *)
let test_a_series_already_held_is_not_filed_again () =
  let lane = [ "lane", "a" ] in
  let gauge = "masc_test_metric_total_filed_once" in
  Store.set_gauge gauge ~labels:lane 0.5;
  Store.set_gauge gauge ~labels:lane 1.5;
  Store.register_gauge ~name:gauge ~help:gauge ~labels:lane ();
  check near "a gauge set twice counts its last value" 1.5 (Store.metric_total gauge);
  let counter = "masc_test_metric_total_filed_once_total" in
  Store.inc_counter counter ~labels:lane ~delta:2.0 ();
  Store.register_counter ~name:counter ~help:counter ~labels:lane ();
  check near "a counter registered after counting keeps one series" 2.0
    (Store.metric_total counter);
  check (option near) "and that series keeps its count" (Some 2.0)
    (Store.get_metric_value counter ~labels:lane ());
  let histogram = "masc_test_metric_total_filed_once_seconds" in
  Store.observe_histogram histogram ~labels:lane 3.0;
  Store.register_histogram ~name:histogram ~help:histogram ~labels:lane ();
  check near "a histogram registered after observing keeps one sum" 3.0
    (Store.metric_total histogram);
  check (option near) "and that sum keeps its value" (Some 3.0)
    (Store.get_metric_value histogram ~labels:lane ())
;;

let test_a_name_never_written_totals_zero () =
  check near "no series" 0.0 (Store.metric_total "masc_test_metric_total_never_written")
;;

let () =
  run
    "otel_metric_total"
    [ ( "totals"
      , [ test_case
            "a total sums its own series and no other"
            `Quick
            test_a_total_sums_its_own_series_and_no_other
        ; test_case
            "every way in counts toward its name"
            `Quick
            test_every_way_in_counts_toward_its_name
        ; test_case
            "a series already held is not filed again"
            `Quick
            test_a_series_already_held_is_not_filed_again
        ; test_case
            "a name never written totals zero"
            `Quick
            test_a_name_never_written_totals_zero
        ] )
    ]
;;
