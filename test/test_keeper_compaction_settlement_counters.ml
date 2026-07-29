(** Which settlement outcome moved the compaction streak.

    [persist_compaction_outcome] is the one place all four outcomes converge on
    [compaction_rt], but the outcome was never recorded: the phase-transition
    log renders a decision string, not the variant, so a live keeper's streak
    could be seen rising without any way to tell whether a reset came from an
    overflow-free turn ([`Recovered]) or an operator commit ([`Committed]).
    These tests pin that every persisted settlement is counted exactly once and
    carries its own outcome label. *)

open Alcotest

module Meta_store = Masc.Keeper_meta_store

let metric_name = Keeper_metrics.(to_string CompactionSettlements)

let counted ~outcome =
  Otel_metric_store_core.metric_value_or_zero
    metric_name
    ~labels:[ "outcome", outcome ]
    ()
;;

let make_meta ~name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Ok meta -> meta
  | Error detail -> failf "keeper meta fixture failed: %s" detail
;;

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       f config)
;;

let register config ~name =
  let meta = make_meta ~name in
  (match Meta_store.write_meta config meta with
   | Ok () -> ()
   | Error msg -> failf "could not persist meta for %s: %s" name msg);
  meta
;;

let settle config ~name ~outcome =
  match Meta_store.persist_compaction_outcome config ~keeper_name:name ~outcome with
  | Ok `Persisted -> ()
  | Ok `No_durable_meta -> failf "%s has no durable meta to settle against" name
  | Error msg -> failf "settlement failed for %s: %s" name msg
;;

(* Each variant gets its own label, so a dashboard can separate a streak reset
   that came from an overflow-free turn from one an operator forced. *)
let test_each_outcome_is_labelled () =
  with_workspace (fun config ->
    let name = "settlement-labels" in
    ignore (register config ~name);
    List.iter
      (fun (outcome, label) ->
         let before = counted ~outcome:label in
         settle config ~name ~outcome;
         check
           (float 0.5)
           (Printf.sprintf "%s is counted under its own label" label)
           (before +. 1.)
           (counted ~outcome:label))
      [ `Committed, "committed"
      ; `Overflow_episode_committed, "overflow_episode_committed"
      ; `Failed, "failed"
      ; `Recovered, "recovered"
      ])
;;

(* The streak arithmetic and the counter must agree: four `Failed` settlements
   are four counted settlements and a streak of four. A count that drifts from
   the durable value would send an operator looking for a bug that is not
   there. *)
let test_count_tracks_the_durable_streak () =
  with_workspace (fun config ->
    let name = "settlement-streak" in
    ignore (register config ~name);
    let before = counted ~outcome:"failed" in
    for _ = 1 to 4 do
      settle config ~name ~outcome:`Failed
    done;
    check
      (float 0.5)
      "four failed settlements are counted four times"
      (before +. 4.)
      (counted ~outcome:"failed");
    match Meta_store.read_meta config name with
    | Ok (Some meta) ->
      check
        int
        "the durable streak matches the count"
        4
        meta.Masc.Keeper_meta_contract.runtime.compaction_rt.consecutive_failures
    | Ok None -> fail "keeper meta disappeared mid-test"
    | Error msg -> failf "meta read failed: %s" msg)
;;

let test_keeper_names_share_one_bounded_series () =
  with_workspace (fun config ->
    let alpha = "settlement-alpha" in
    let beta = "settlement-beta" in
    ignore (register config ~name:alpha);
    ignore (register config ~name:beta);
    let before = counted ~outcome:"failed" in
    settle config ~name:alpha ~outcome:`Failed;
    settle config ~name:beta ~outcome:`Failed;
    check
      (float 0.5)
      "both keepers increment the same outcome series"
      (before +. 2.)
      (counted ~outcome:"failed");
    let settlement_metrics =
      Otel_metric_store_core.snapshot ()
      |> List.filter (fun (metric : Otel_metric_store_core.metric) ->
        String.equal metric.name metric_name)
    in
    check bool "settlement series never carry Keeper identity" true
      (List.for_all
         (fun (metric : Otel_metric_store_core.metric) ->
            not (List.mem_assoc "keeper" metric.labels))
         settlement_metrics))
;;

(* No durable meta means no settlement was persisted and no streak moved, so
   counting one would overstate the population the series describes. *)
let test_unregistered_keeper_is_not_counted () =
  with_workspace (fun config ->
    let name = "settlement-unregistered" in
    let before = counted ~outcome:"failed" in
    (match
       Meta_store.persist_compaction_outcome config ~keeper_name:name ~outcome:`Failed
     with
     | Ok `No_durable_meta -> ()
     | Ok `Persisted -> fail "an unregistered keeper must not persist a settlement"
     | Error msg -> failf "unexpected settlement error: %s" msg);
    check
      (float 0.5)
      "an unpersisted settlement is not counted"
      before
      (counted ~outcome:"failed"))
;;

let test_metric_name_is_stable () =
  check
    string
    "dashboards and alerts key off this name"
    "masc_keeper_compaction_settlements_total"
    metric_name
;;

let () =
  run
    "keeper compaction settlement counters"
    [ ( "settlement"
      , [ test_case "each outcome is labelled" `Quick test_each_outcome_is_labelled
        ; test_case
            "count tracks the durable streak"
            `Quick
            test_count_tracks_the_durable_streak
        ; test_case
            "keeper names share one bounded series"
            `Quick
            test_keeper_names_share_one_bounded_series
        ; test_case
            "an unregistered keeper is not counted"
            `Quick
            test_unregistered_keeper_is_not_counted
        ; test_case "metric name is stable" `Quick test_metric_name_is_stable
        ] )
    ]
;;
