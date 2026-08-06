(** A declared counter exports its 0-cell before it ever fires.

    [Otel_metric_store_core.declare_counter] exists to remove the
    absence-vs-zero ambiguity: a counter that has not fired IS 0, so the
    unlabeled cell is registered at module-init time. A name passed straight to
    [inc_counter] skips that, and the series does not exist until the first
    increment.

    masc_keeper_lifecycle_malformed_total was the one metric in lib/ emitted
    that way, and the comment at its call site says it exists so
    [rate(...)] alerts catch a lifecycle encoding regression -- an alert that
    cannot be written, let alone validated, while the series is missing.

    [get_metric_value] is the discriminator the assertion needs:
    [None] for absent, [Some 0.] for registered-and-unfired.
    [metric_value_or_zero] cannot tell those apart, which is the ambiguity
    itself. *)

open Alcotest

let value name = Otel_metric_store_core.get_metric_value name ()

let check_zero_cell label name =
  match value name with
  | Some observed ->
    check (float 0.0) (label ^ ": exports 0 before firing") 0.0 observed
  | None ->
    failf
      "%s: %S is absent from the store, so declare_counter never ran for it"
      label
      name
;;

let test_lifecycle_malformed_is_declared () =
  check_zero_cell
    "keeper lifecycle malformed"
    Otel_builtin_metric_names.metric_keeper_lifecycle_malformed
;;

(* Control: a counter that was already declared. If this one were absent too,
   the assertion above would be measuring test setup rather than the fix. *)
let test_control_counter_is_declared () =
  check_zero_cell "telemetry coverage gap" Otel_builtin_metric_names.metric_telemetry_coverage_gap
;;

(* The discriminator has to actually discriminate: a name nothing declares must
   read as absent, not as zero. Without this, the two cases above would pass
   against any implementation that returned Some 0.0 for everything. *)
let test_undeclared_name_reads_absent () =
  match value "masc_counter_that_no_module_declares_total" with
  | None -> ()
  | Some observed ->
    failf
      "an undeclared name read as %f; get_metric_value cannot distinguish \
       absent from zero, so the other cases here prove nothing"
      observed
;;

let () =
  run
    "metric zero-cell declaration"
    [ ( "declared counters"
      , [ test_case
            "keeper lifecycle malformed"
            `Quick
            test_lifecycle_malformed_is_declared
        ; test_case "control counter" `Quick test_control_counter_is_declared
        ; test_case
            "undeclared name reads absent"
            `Quick
            test_undeclared_name_reads_absent
        ] )
    ]
;;
