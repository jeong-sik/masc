(** A bucket's [le] label must name the bound the comparison actually used.

    The label is produced from the registered bound, and a lossy rendering
    makes the exported bucket advertise a threshold the store never compared
    against: [Printf.sprintf "%g" 1048576.] yields ["1.04858e+06"], which
    parses back to 1048580. A dashboard reading that label would attribute
    observations to a bound four bytes away from the real one, and byte-scale
    bounds are exactly what a request-size histogram registers.

    The expected labels below are written as literals rather than re-derived
    from the bounds, so a change to the rendering has to be stated here to
    pass rather than silently agreeing with itself. *)

open Alcotest

let bucket_count ~name ~le =
  Otel_metric_store_core.metric_value_or_zero
    (name ^ "_bucket")
    ~labels:[ "le", le ]
    ()
;;

let observe_into ~name ~bounds value =
  Otel_metric_store_core.register_histogram_buckets name bounds;
  Otel_metric_store_core.observe_histogram name value
;;

(* MiB-scale bounds need more than six significant digits, which is where a
   default [%g] rendering starts losing them. *)
let test_mib_scale_bounds_keep_their_exact_label () =
  let name = "masc_test_histogram_mib_bounds" in
  observe_into ~name ~bounds:[ 262144.; 524288.; 1048576.; 2097152.; 16777216. ] 1.0;
  List.iter
    (fun le ->
       check
         (float 0.5)
         (Printf.sprintf "an observation below every bound lands in le=%s" le)
         1.
         (bucket_count ~name ~le))
    [ "262144"; "524288"; "1048576"; "2097152"; "16777216" ]
;;

(* Sub-second bounds must not pick up a spurious exponent or trailing dot. *)
let test_fractional_bounds_keep_their_exact_label () =
  let name = "masc_test_histogram_fractional_bounds" in
  observe_into ~name ~bounds:[ 0.001; 0.025; 0.5; 1.0; 2.5; 1000. ] 0.0;
  List.iter
    (fun le ->
       check
         (float 0.5)
         (Printf.sprintf "an observation below every bound lands in le=%s" le)
         1.
         (bucket_count ~name ~le))
    [ "0.001"; "0.025"; "0.5"; "1"; "2.5"; "1000" ]
;;

(* Without this, a label that named the wrong threshold would still satisfy the
   checks above, because nothing would have compared against it. *)
let test_bounds_below_the_observation_stay_empty () =
  let name = "masc_test_histogram_boundary" in
  observe_into ~name ~bounds:[ 1048576.; 2097152. ] 1_500_000.;
  check
    (float 0.5)
    "a bound below the observation stays empty"
    0.
    (bucket_count ~name ~le:"1048576");
  check
    (float 0.5)
    "a bound above the observation counts it"
    1.
    (bucket_count ~name ~le:"2097152")
;;

let () =
  run
    "otel histogram bucket labels"
    [ ( "le labels"
      , [ test_case
            "MiB-scale bounds keep their exact label"
            `Quick
            test_mib_scale_bounds_keep_their_exact_label
        ; test_case
            "fractional bounds keep their exact label"
            `Quick
            test_fractional_bounds_keep_their_exact_label
        ; test_case
            "bounds below the observation stay empty"
            `Quick
            test_bounds_below_the_observation_stay_empty
        ] )
    ]
;;
