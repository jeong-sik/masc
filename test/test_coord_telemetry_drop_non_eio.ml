(** #13096 review (copilot): regression coverage for the Coord telemetry-drop
    helper. Backend setup now falls back to Memory outside Eio, so this test
    targets the helper directly instead of relying on backend-specific
    [Effect.Unhandled] behavior. The invariant is still the same:
    [masc_coord_telemetry_drop_total{event_family=...,event_kind=...}] must
    increment so dropped audit/telemetry writes remain observable.

    RFC-0088 §4 Option A (2026-05-15): [For_testing.warn_telemetry_drop]
    now takes a typed [Coord_telemetry_drop_event.t] instead of two free
    strings. The Prometheus label values remain byte-for-byte identical
    (["agent_lifecycle", "leave"] / ["agent_lifecycle", "join"]) so the
    assertions below — which still pin the wire label values — are the
    correct regression coverage for the swap-over. *)

open Masc_mcp

let counter_value ~event_family ~event_kind =
  Prometheus.metric_value_or_zero
    Prometheus.metric_coord_telemetry_drop
    ~labels:[ ("event_family", event_family); ("event_kind", event_kind) ]
    ()

let test_lifecycle_drop_increments_counter () =
  let event : Coord_telemetry_drop_event.t =
    Agent_lifecycle Lifecycle_leave
  in
  let event_family = Coord_telemetry_drop_event.family_to_wire event in
  let event_kind = Coord_telemetry_drop_event.kind_to_wire event in
  let before = counter_value ~event_family ~event_kind in
  Coord.For_testing.warn_telemetry_drop ~event
    (Failure "simulated non-Eio telemetry drop");
  let after = counter_value ~event_family ~event_kind in
  Alcotest.(check (float 0.001))
    "drop counter increments by exactly 1 for the leave label"
    1.0 (after -. before)

(* Same path, join variant: the warn label switches to "join" so a
   single regression on the wrong label key (e.g. hard-coded "leave")
   would still pass the test above. *)
let test_lifecycle_drop_join_label () =
  let event : Coord_telemetry_drop_event.t =
    Agent_lifecycle Lifecycle_join
  in
  let event_family = Coord_telemetry_drop_event.family_to_wire event in
  let event_kind = Coord_telemetry_drop_event.kind_to_wire event in
  let before = counter_value ~event_family ~event_kind in
  Coord.For_testing.warn_telemetry_drop ~event
    (Failure "simulated non-Eio telemetry drop");
  let after = counter_value ~event_family ~event_kind in
  Alcotest.(check (float 0.001))
    "drop counter increments by exactly 1 for the join label"
    1.0 (after -. before)

(* RFC-0088 §4 Option A: confirm the wire mapping is byte-for-byte
   compatible with the pre-typed call sites. If a future refactor
   accidentally rewires the wire labels (e.g. drops the snake_case),
   Grafana dashboards built on the existing labels would silently
   stop matching. *)
let test_wire_mapping_stable () =
  Alcotest.(check string)
    "agent_lifecycle family"
    "agent_lifecycle"
    (Coord_telemetry_drop_event.family_to_wire
       (Agent_lifecycle Lifecycle_leave));
  Alcotest.(check string)
    "agent_lifecycle / leave kind"
    "leave"
    (Coord_telemetry_drop_event.kind_to_wire
       (Agent_lifecycle Lifecycle_leave));
  Alcotest.(check string)
    "task_transition family"
    "task_transition"
    (Coord_telemetry_drop_event.family_to_wire
       (Task_transition Masc_domain.Claim));
  Alcotest.(check string)
    "task_transition / claim kind"
    "claim"
    (Coord_telemetry_drop_event.kind_to_wire
       (Task_transition Masc_domain.Claim));
  Alcotest.(check string)
    "accountability family"
    "accountability"
    (Coord_telemetry_drop_event.family_to_wire
       (Accountability Masc_domain.Done_action));
  Alcotest.(check string)
    "accountability / done kind"
    "done"
    (Coord_telemetry_drop_event.kind_to_wire
       (Accountability Masc_domain.Done_action))

let () =
  Alcotest.run "coord_telemetry_drop_non_eio"
    [
      ( "non_eio_drop",
        [
          Alcotest.test_case "leave label increments counter" `Quick
            test_lifecycle_drop_increments_counter;
          Alcotest.test_case "join label increments counter" `Quick
            test_lifecycle_drop_join_label;
          Alcotest.test_case "wire mapping stable across all 3 families"
            `Quick test_wire_mapping_stable;
        ] );
    ]
