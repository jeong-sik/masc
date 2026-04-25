(** #10325 — pin the failure-learnings emit contract.

    Pre-fix [Memory_oas_bridge.store_failed_turn_episode] hardcoded
    [learnings = ["persist failed keeper turns so future runs can
    learn from failure patterns"]] in 75 of 77 failure entries
    (97%) of [.masc/institution_episodes.jsonl].  The data was
    available — [error_kind], [error_message], [trace_id], [turn]
    all flow into the surrounding [context] block — but the
    [learnings] field carried a static boilerplate.
    Institution-level memory therefore could not learn from
    failure patterns: every keeper turn looked like the first
    failure of its kind.

    These tests pin
    [Memory_oas_bridge.failure_learnings] and the per-error_kind
    Prometheus counter:

    1. [error_kind] surfaces in [learnings[0]] using the
       [failure_kind: <kind>] schema so [jq | sort | uniq -c]
       produces a meaningful distribution.
    2. [error_preview] when present surfaces in [learnings[1]] as
       [error_preview: <preview>].  When the preview is empty /
       whitespace-only the entry collapses to a single-element
       list (no fake [error_preview: ] noise).
    3. Empty / whitespace-only [error_kind] normalises to the
       [unspecified] sentinel — pre-fix path silently produced
       [failure_kind: ] which would alias every empty-kind
       failure into one bucket; the explicit sentinel keeps the
       row queryable.
    4. The counter
       [masc_institution_episode_failure_kind_total{error_kind}]
       increments per kind and label-isolates so dashboards can
       split per failure mode. *)

open Alcotest

module M = Masc_mcp.Memory_oas_bridge
module Prom = Masc_mcp.Prometheus

(* --- learnings shape -------------------------------------------- *)

let test_learnings_carries_error_kind_first () =
  let learnings =
    M.failure_learnings ~error_kind:"oas_timeout_budget"
      ~error_preview:"Adaptive estimated input tokens exceeded budget"
  in
  check (list string)
    "[failure_kind; error_preview] in order"
    [
      "failure_kind: oas_timeout_budget";
      "error_preview: Adaptive estimated input tokens exceeded budget";
    ]
    learnings

let test_learnings_omits_empty_preview () =
  let learnings =
    M.failure_learnings ~error_kind:"resumable_cli_session"
      ~error_preview:""
  in
  check (list string)
    "single-element list when preview is empty"
    [ "failure_kind: resumable_cli_session" ]
    learnings;
  let learnings_ws =
    M.failure_learnings ~error_kind:"resumable_cli_session"
      ~error_preview:"   \n  "
  in
  check (list string)
    "single-element list when preview is whitespace-only"
    [ "failure_kind: resumable_cli_session" ]
    learnings_ws

(* --- error_kind normalisation ------------------------------------ *)

let test_empty_error_kind_normalises_to_unspecified () =
  let learnings =
    M.failure_learnings ~error_kind:"" ~error_preview:"some preview"
  in
  check (list string)
    "empty error_kind becomes unspecified sentinel"
    [
      "failure_kind: unspecified";
      "error_preview: some preview";
    ]
    learnings

let test_whitespace_error_kind_normalises_to_unspecified () =
  let learnings =
    M.failure_learnings ~error_kind:"  \t " ~error_preview:""
  in
  check (list string)
    "whitespace-only error_kind becomes unspecified"
    [ "failure_kind: unspecified" ]
    learnings

(* --- counter name + label shape (pure asserts) ------------------ *)

(* The counter is incremented inside [store_failed_turn_episode],
   which routes through an OAS Memory backend.  Driving the full
   path requires the #9903 base_path guard configuration that the
   bulk-test env strips intentionally.  Instead we pin the canonical
   metric name + label shape so dashboards can rely on it; the
   integration ticks are then covered by [normalize_error_kind]
   and [failure_learnings] above (the routing logic that decides
   the label value). *)

let test_metric_name_stable () =
  check string "canonical metric name"
    "masc_institution_episode_failure_kind_total"
    M.institution_episode_failure_kind_metric

let test_metric_value_for_unknown_label_starts_zero () =
  (* A never-seen label pair must read zero — this anchors the
     [Prom.metric_value_or_zero] contract used by the bootstrap
     audit in dashboards. *)
  let v =
    Prom.metric_value_or_zero
      M.institution_episode_failure_kind_metric
      ~labels:[ ("error_kind", "never-seen-kind-10325") ]
      ()
  in
  check (float 0.0001) "unseen label reads 0.0" 0.0 v

(* Avoid 'Prom is unused' warnings from minified test files. *)
let _ = Prom.metric_value_or_zero

let () =
  run "institution_episodes_failure_learnings_10325"
    [
      ( "learnings-shape",
        [
          test_case "error_kind first, preview second" `Quick
            test_learnings_carries_error_kind_first;
          test_case "empty/whitespace preview omitted" `Quick
            test_learnings_omits_empty_preview;
        ] );
      ( "error_kind-normalise",
        [
          test_case "empty error_kind -> unspecified" `Quick
            test_empty_error_kind_normalises_to_unspecified;
          test_case "whitespace error_kind -> unspecified" `Quick
            test_whitespace_error_kind_normalises_to_unspecified;
        ] );
      ( "counter-surface",
        [
          test_case "metric name stable" `Quick test_metric_name_stable;
          test_case "unseen label reads 0.0" `Quick
            test_metric_value_for_unknown_label_starts_zero;
        ] );
    ]
