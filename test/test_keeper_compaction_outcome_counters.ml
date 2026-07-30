(** Which outcome moved the compaction streak.

    [persist_compaction_outcome] is the one place all four outcomes converge on
    [compaction_rt], but the outcome was never recorded: the phase-transition
    log renders a decision string, not the variant, so a live keeper's streak
    could be seen rising without any way to tell whether a reset came from an
    overflow-free turn ([`Recovered]) or an operator commit ([`Committed]).
    These tests pin that every persisted outcome is counted exactly once and
    carries its own label. *)

open Alcotest

module Meta_store = Masc.Keeper_meta_store

let metric_name = Keeper_metrics.(to_string CompactionOutcomes)

let counted ~keeper_name ~outcome =
  Otel_metric_store_core.metric_value_or_zero
    metric_name
    ~labels:[ "keeper", keeper_name; "outcome", outcome ]
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

let persist_outcome config ~name ~outcome =
  match Meta_store.persist_compaction_outcome config ~keeper_name:name ~outcome with
  | Ok `Persisted -> ()
  | Ok `No_durable_meta -> failf "%s has no durable meta to update" name
  | Error msg -> failf "outcome persistence failed for %s: %s" name msg
;;

(* Each variant gets its own label, so a dashboard can separate a streak reset
   that came from an overflow-free turn from one an operator forced. *)
let test_each_outcome_is_labelled () =
  with_workspace (fun config ->
    let name = "outcome-labels" in
    ignore (register config ~name);
    List.iter
      (fun (outcome, label) ->
         let before = counted ~keeper_name:name ~outcome:label in
         persist_outcome config ~name ~outcome;
         check
           (float 0.5)
           (Printf.sprintf "%s is counted under its own label" label)
           (before +. 1.)
           (counted ~keeper_name:name ~outcome:label))
      [ `Committed, "committed"
      ; `Overflow_episode_committed, "overflow_episode_committed"
      ; `Failed, "failed"
      ; `Recovered, "recovered"
      ])
;;

(* The streak arithmetic and the counter must agree: four persisted [`Failed]
   outcomes are four counted outcomes and a streak of four. A count that drifts from
   the durable value would send an operator looking for a bug that is not
   there. *)
let test_count_tracks_the_durable_streak () =
  with_workspace (fun config ->
    let name = "outcome-streak" in
    ignore (register config ~name);
    let before = counted ~keeper_name:name ~outcome:"failed" in
    for _ = 1 to 4 do
      persist_outcome config ~name ~outcome:`Failed
    done;
    check
      (float 0.5)
      "four failed outcomes are counted four times"
      (before +. 4.)
      (counted ~keeper_name:name ~outcome:"failed");
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

let test_attributes_the_outcome_to_its_keeper () =
  with_workspace (fun config ->
    let alpha = "outcome-alpha" in
    let beta = "outcome-beta" in
    ignore (register config ~name:alpha);
    ignore (register config ~name:beta);
    let beta_before = counted ~keeper_name:beta ~outcome:"failed" in
    persist_outcome config ~name:alpha ~outcome:`Failed;
    check
      (float 0.5)
      "another keeper's series is untouched"
      beta_before
      (counted ~keeper_name:beta ~outcome:"failed"))
;;

(* No durable meta means no outcome was persisted and no streak moved, so
   counting one would overstate the population the series describes. *)
let test_unregistered_keeper_is_not_counted () =
  with_workspace (fun config ->
    let name = "outcome-unregistered" in
    let before = counted ~keeper_name:name ~outcome:"failed" in
    (match
       Meta_store.persist_compaction_outcome config ~keeper_name:name ~outcome:`Failed
     with
     | Ok `No_durable_meta -> ()
     | Ok `Persisted -> fail "an unregistered keeper must not persist an outcome"
     | Error msg -> failf "unexpected outcome persistence error: %s" msg);
    check
      (float 0.5)
      "an unpersisted outcome is not counted"
      before
      (counted ~keeper_name:name ~outcome:"failed"))
;;

let test_metric_name_is_stable () =
  check
    string
    "dashboards and alerts key off this name"
    "masc_keeper_compaction_outcomes_total"
    metric_name
;;

let () =
  run
    "keeper compaction outcome counters"
    [ ( "outcome"
      , [ test_case "each outcome is labelled" `Quick test_each_outcome_is_labelled
        ; test_case
            "count tracks the durable streak"
            `Quick
            test_count_tracks_the_durable_streak
        ; test_case
            "attributes the outcome to its keeper"
            `Quick
            test_attributes_the_outcome_to_its_keeper
        ; test_case
            "an unregistered keeper is not counted"
            `Quick
            test_unregistered_keeper_is_not_counted
        ; test_case "metric name is stable" `Quick test_metric_name_is_stable
        ] )
    ]
;;
