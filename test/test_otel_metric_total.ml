(** [Otel_metric_store_core.metric_total] adds up the series filed under one
    name. [/health] reads three such totals per request, and the store holds a
    series for every label set of every metric, so a total reads only its own
    name's series.

    The behavioural cases pin what a total counts: every series of its name,
    however the series entered the store, and no series of another name. The
    source-structure case pins how the index stays whole: a series enters the
    table only through [add_series], which files it under its name. *)

open Alcotest
module Store = Otel_metric_store_core

let store_source = "lib/otel_metric_store/otel_metric_store_core.ml"
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

let test_every_way_in_counts_toward_its_name () =
  let gauge = "masc_test_metric_total_gauge" in
  Store.set_gauge gauge ~labels:[ "via", "set" ] 1.5;
  Store.inc_gauge gauge ~labels:[ "via", "inc" ] ~delta:2.0 ();
  Store.dec_gauge gauge ~labels:[ "via", "dec" ] ~delta:0.5 ();
  Store.register_gauge ~name:gauge ~help:gauge ~labels:[ "via", "register" ] ();
  check near "gauge series from set, inc, dec and register" 3.0 (Store.metric_total gauge);
  let histogram = "masc_test_metric_total_seconds" in
  Store.register_histogram_buckets histogram [ 1.0; 10.0 ];
  Store.observe_histogram histogram ~labels:[ "via", "a" ] 0.5;
  Store.observe_histogram histogram ~labels:[ "via", "b" ] 5.0;
  check near "the histogram's sum series" 5.5 (Store.metric_total histogram);
  check
    near
    "its count series, under their own name"
    2.0
    (Store.metric_total (Store.histogram_count_name histogram));
  (* 0.5 lands in le=1, le=10 and +Inf; 5.0 in le=10 and +Inf. *)
  check
    near
    "its bucket series, under their own name"
    5.0
    (Store.metric_total (histogram ^ "_bucket"))
;;

let test_a_name_never_written_totals_zero () =
  check near "no series" 0.0 (Store.metric_total "masc_test_metric_total_never_written")
;;

let test_the_table_is_filled_only_through_add_series () =
  check
    int
    "the store has one Hashtbl.add"
    1
    (Ast_grep.count_calls ~module_path:store_source ~callee:"Hashtbl.add");
  check
    int
    "and it is add_series'"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:store_source
       ~binding_name:"add_series"
       ~callee:"Hashtbl.add")
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
            "a name never written totals zero"
            `Quick
            test_a_name_never_written_totals_zero
        ] )
    ; ( "source structure"
      , [ test_case
            "the table is filled only through add_series"
            `Quick
            test_the_table_is_filled_only_through_add_series
        ] )
    ]
;;
