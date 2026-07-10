(** Zero-fill registration regression tests.

    Counters declared through [Otel_metric_store_core.declare_counter]
    (metric-name modules) and the [Keeper_metrics] module-init sweep must
    export an unlabeled 0-cell from process start, so Grafana can
    distinguish "never fired" (series at 0) from "not wired" (no series).
    See RFC-0217 (OTel single backend) and the absence-vs-zero finding in
    the 2026-06-10 telemetry audit. *)

open Alcotest

let find_unlabeled name =
  Otel_metric_store_core.snapshot ()
  |> List.find_opt (fun (m : Otel_metric_store_core.metric) ->
    String.equal m.name name && m.labels = [])

let test_declare_counter_registers_zero_cell () =
  let name = "masc_test_zero_fill_probe_total" in
  let returned = Otel_metric_store_core.declare_counter name in
  check string "declare_counter returns the name" name returned;
  match find_unlabeled name with
  | None -> fail "declared counter must have an unlabeled cell"
  | Some m ->
    check bool "kind is Counter" true (m.metric_type = Otel_metric_store_core.Counter);
    check (float 0.0) "initial value is 0" 0.0 m.value

let test_declared_counter_still_increments () =
  let name = "masc_test_zero_fill_inc_probe_total" in
  let _ = Otel_metric_store_core.declare_counter name in
  Otel_metric_store_core.inc_counter name ();
  match find_unlabeled name with
  | None -> fail "cell must exist"
  | Some m -> check (float 0.0) "value is 1 after inc" 1.0 m.value

let test_name_module_constant_zero_filled () =
  (* Module-init effect of the converted name modules: a counter constant
     that has never been incremented in this binary is already present. *)
  match find_unlabeled Otel_core_metric_names.metric_after_turn_hook with
  | None -> fail "masc_after_turn_hook_total must be registered at module init"
  | Some m ->
    check bool "kind is Counter" true (m.metric_type = Otel_metric_store_core.Counter)

let test_keeper_metrics_zero_filled () =
  match find_unlabeled Keeper_metrics.(to_string WriteMetaFailures) with
  | None -> fail "masc_keeper_write_meta_failures_total must be registered at module init"
  | Some m ->
    check (float 0.0) "keeper failure counter starts at 0" 0.0 m.value

let test_chat_transport_metric_zero_filled () =
  match find_unlabeled Keeper_metrics.(to_string ChatTransportFailures) with
  | None ->
    fail "masc_keeper_chat_transport_failures_total must be registered at module init"
  | Some m ->
    check (float 0.0) "chat transport failure counter starts at 0" 0.0 m.value

let test_keeper_metrics_all_complete () =
  (* [Keeper_metrics.all] is generated from the variant declaration, so
     constructor coverage is guaranteed by compilation rather than a numeric
     pin.  Keep the independent wire-name uniqueness contract here. *)
  let names = List.map Keeper_metrics.to_string Keeper_metrics.all in
  check int "to_string is injective over all"
    (List.length names)
    (List.length (List.sort_uniq String.compare names))

let () =
  run "otel_zero_fill"
    [ ( "declare"
      , [ test_case "registers zero cell" `Quick test_declare_counter_registers_zero_cell
        ; test_case "increment still works" `Quick test_declared_counter_still_increments
        ] )
    ; ( "module-init"
      , [ test_case "name module constant" `Quick test_name_module_constant_zero_filled
        ; test_case "keeper metrics" `Quick test_keeper_metrics_zero_filled
        ; test_case "chat transport metric" `Quick
            test_chat_transport_metric_zero_filled
        ; test_case "keeper all complete" `Quick test_keeper_metrics_all_complete
        ] )
    ]
