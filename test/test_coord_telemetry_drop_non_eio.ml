(** #13096 review (copilot): regression coverage for the non-Eio drop
    path in Coord catch sites. When the lifecycle / task hooks are invoked
    outside any Eio scheduler, date-split audit/telemetry writes raise
    [Stdlib.Effect.Unhandled]; the hook must absorb that and increment
    [masc_coord_telemetry_drop_total{event_family=...,event_kind=...}]
    so the drop is observable in Prometheus / Grafana. *)

open Masc_mcp

let counter_value ~event_family ~event_kind =
  Prometheus.metric_value_or_zero
    Prometheus.metric_coord_telemetry_drop
    ~labels:[ ("event_family", event_family); ("event_kind", event_kind) ]
    ()

let with_temp_base f =
  let dir = Filename.temp_file "masc_coord_telem_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      try
        let cmd = Printf.sprintf "rm -rf %s" (Filename.quote dir) in
        let _ : int = Sys.command cmd in
        ()
      with _ -> ())
    (fun () -> f dir)

let check_counter_increment ~event_family ~event_kind before =
  let after = counter_value ~event_family ~event_kind in
  Alcotest.(check (float 0.001))
    (Printf.sprintf "drop counter increments for %s/%s" event_family event_kind)
    1.0 (after -. before)

(* Calling the lifecycle observer outside any Eio scheduler must:
   - not raise (the hook contract is "do not break the caller"), and
   - increment the drop counter for the matching labels. *)
let test_lifecycle_drop_increments_counter () =
  with_temp_base (fun base ->
    let config = Coord.default_config base in
    let observe = Atomic.get Coord_hooks.observe_agent_lifecycle_fn in
    let event_family = "agent_lifecycle" in
    let event_kind = "leave" in
    let before = counter_value ~event_family ~event_kind in
    (* No Eio scheduler running on this fiber: Audit_log / Telemetry_eio
       raise Stdlib.Effect.Unhandled inside [observe_agent_lifecycle];
       the hook must catch and warn + bump the counter. *)
    (try
       observe config
         ~agent_id:"telemetry-drop-test"
         ~event:Coord_hooks.Lifecycle_leave
         ~details:`Null
     with exn ->
       Alcotest.failf
         "lifecycle hook leaked exception in non-Eio context: %s"
         (Printexc.to_string exn));
    check_counter_increment ~event_family ~event_kind before)

(* Same path, join variant: the warn label switches to "join" so a
   single regression on the wrong label key (e.g. hard-coded "leave")
   would still pass the test above. *)
let test_lifecycle_drop_join_label () =
  with_temp_base (fun base ->
    let config = Coord.default_config base in
    let observe = Atomic.get Coord_hooks.observe_agent_lifecycle_fn in
    let event_family = "agent_lifecycle" in
    let event_kind = "join" in
    let before = counter_value ~event_family ~event_kind in
    (try
       observe config
         ~agent_id:"telemetry-drop-test-join"
         ~event:Coord_hooks.Lifecycle_join
         ~details:`Null
     with exn ->
       Alcotest.failf
         "lifecycle hook leaked exception in non-Eio context: %s"
         (Printexc.to_string exn));
    check_counter_increment ~event_family ~event_kind before)

let test_task_transition_drop_increments_counter () =
  with_temp_base (fun base ->
    let config = Coord.default_config base in
    let observe = Atomic.get Coord_hooks.observe_task_transition_fn in
    let event_family = "task_transition" in
    let event_kind = "claim" in
    let before = counter_value ~event_family ~event_kind in
    (try
       observe config
         ~agent_name:"telemetry-drop-task-agent"
         ~task_id:"telemetry-drop-task"
         ~transition:Masc_domain.Claim
         ~details:`Null
     with exn ->
       Alcotest.failf
         "task transition hook leaked exception in non-Eio context: %s"
         (Printexc.to_string exn));
    check_counter_increment ~event_family ~event_kind before)

let () =
  Alcotest.run "coord_telemetry_drop_non_eio"
    [
      ( "non_eio_drop",
        [
          Alcotest.test_case "leave label increments counter" `Quick
            test_lifecycle_drop_increments_counter;
          Alcotest.test_case "join label increments counter" `Quick
            test_lifecycle_drop_join_label;
          Alcotest.test_case "task transition increments counter" `Quick
            test_task_transition_drop_increments_counter;
        ] );
    ]
