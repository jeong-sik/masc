(** test_cascade_strategy_labels — pure label-uniqueness tests for the
    [Cascade_strategy.kind] and [Cascade_strategy_trace.event_kind]
    ADTs.

    Step 15 (partial) of the bloodflow restoration plan, mirrors the
    pure-helper coverage shape used by [test_keeper_typed_labels],
    [test_auth_resolve_labels], and [test_keeper_classifier_helper].

    These labels are emitted by:
    - [Cascade_strategy.kind_to_string] — surfaced as the [strategy]
      label on the [cascade_strategy_decisions] Prometheus counter
      (see [bump_prometheus_counter] in cascade_strategy_trace.ml)
      and on the dashboard cascade card.
    - [Cascade_strategy_trace.kind_to_string] — surfaced as the
      [kind] label on the same counter and as the [kind] field on
      the dashboard JSON projection.

    Both label sets are joined on [infrastructure/monitoring/cascade-slo.yml]
    and the operator-facing dashboard.  A silent rename or duplicate
    would break the SLO query and the dashboard simultaneously, so we
    pin them here. *)

open Masc_mcp

(* ── Helpers ─────────────────────────────────────────────────── *)

let duplicates labels =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun s ->
      let dup = Hashtbl.mem seen s in
      Hashtbl.replace seen s ();
      dup)
    labels

(* ── Cascade_strategy.kind ───────────────────────────────────── *)

let test_cascade_strategy_kind_labels_unique () =
  let labels =
    List.map Cascade_strategy.kind_to_string Cascade_strategy.all_kinds
  in
  Alcotest.(check (list string))
    "no duplicate cascade_strategy.kind labels" [] (duplicates labels)

let test_cascade_strategy_kind_labels_lowercase () =
  List.iter
    (fun k ->
      let s = Cascade_strategy.kind_to_string k in
      Alcotest.(check string)
        ("label is lowercase: " ^ s)
        (String.lowercase_ascii s) s)
    Cascade_strategy.all_kinds

let test_cascade_strategy_all_kinds_documented_seven () =
  Alcotest.(check int)
    "all_kinds covers the 7 documented strategies (Failover, \
     Capacity_aware, Weighted_random, Circuit_breaker_cycling, \
     Priority_tier, Sticky, Round_robin)"
    7
    (List.length Cascade_strategy.all_kinds)

(* ── Cascade_strategy_trace.event_kind ───────────────────────── *)

let all_event_kinds : Cascade_strategy_trace.event_kind list =
  [ Ordered; Filtered_empty; Exhausted ]

let test_cascade_strategy_trace_kind_labels_unique () =
  let labels =
    List.map Cascade_strategy_trace.kind_to_string all_event_kinds
  in
  Alcotest.(check (list string))
    "no duplicate cascade_strategy_trace.event_kind labels" []
    (duplicates labels)

let test_cascade_strategy_trace_kind_labels_match_dashboard_doc () =
  (* Asserts the exact strings documented at
     cascade_strategy_trace.mli :: kind_to_string. *)
  let pairs : (Cascade_strategy_trace.event_kind * string) list =
    [
      (Ordered, "ordered");
      (Filtered_empty, "filtered_empty");
      (Exhausted, "exhausted");
    ]
  in
  List.iter
    (fun (k, expected) ->
      Alcotest.(check string)
        ("documented label for " ^ expected)
        expected
        (Cascade_strategy_trace.kind_to_string k))
    pairs

let () =
  Alcotest.run "cascade_strategy_labels"
    [
      ( "cascade_strategy.kind",
        [
          Alcotest.test_case "labels unique" `Quick
            test_cascade_strategy_kind_labels_unique;
          Alcotest.test_case "labels lowercase" `Quick
            test_cascade_strategy_kind_labels_lowercase;
          Alcotest.test_case "all_kinds documents seven strategies"
            `Quick test_cascade_strategy_all_kinds_documented_seven;
        ] );
      ( "cascade_strategy_trace.event_kind",
        [
          Alcotest.test_case "labels unique" `Quick
            test_cascade_strategy_trace_kind_labels_unique;
          Alcotest.test_case "labels match dashboard documentation"
            `Quick test_cascade_strategy_trace_kind_labels_match_dashboard_doc;
        ] );
    ]
