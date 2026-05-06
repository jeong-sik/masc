(** #13096 review (copilot): regression coverage for the Coord telemetry-drop
    helper. Backend setup now falls back to Memory outside Eio, so this test
    targets the helper directly instead of relying on backend-specific
    [Effect.Unhandled] behavior. The invariant is still the same:
    [masc_coord_telemetry_drop_total{event_family=...,event_kind=...}] must
    increment so dropped audit/telemetry writes remain observable. *)

open Masc_mcp

let counter_value ~event_family ~event_kind =
  Prometheus.metric_value_or_zero
    Prometheus.metric_coord_telemetry_drop
    ~labels:[ ("event_family", event_family); ("event_kind", event_kind) ]
    ()

let test_lifecycle_drop_increments_counter () =
  let event_family = "agent_lifecycle" in
  let event_kind = "leave" in
  let before = counter_value ~event_family ~event_kind in
  Coord.For_testing.warn_telemetry_drop ~event_family ~event_kind
    (Failure "simulated non-Eio telemetry drop");
  let after = counter_value ~event_family ~event_kind in
  Alcotest.(check (float 0.001))
    "drop counter increments by exactly 1 for the leave label"
    1.0 (after -. before)

(* Same path, join variant: the warn label switches to "join" so a
   single regression on the wrong label key (e.g. hard-coded "leave")
   would still pass the test above. *)
let test_lifecycle_drop_join_label () =
  let event_family = "agent_lifecycle" in
  let event_kind = "join" in
  let before = counter_value ~event_family ~event_kind in
  Coord.For_testing.warn_telemetry_drop ~event_family ~event_kind
    (Failure "simulated non-Eio telemetry drop");
  let after = counter_value ~event_family ~event_kind in
  Alcotest.(check (float 0.001))
    "drop counter increments by exactly 1 for the join label"
    1.0 (after -. before)

let () =
  Alcotest.run "coord_telemetry_drop_non_eio"
    [
      ( "non_eio_drop",
        [
          Alcotest.test_case "leave label increments counter" `Quick
            test_lifecycle_drop_increments_counter;
          Alcotest.test_case "join label increments counter" `Quick
            test_lifecycle_drop_join_label;
        ] );
    ]
