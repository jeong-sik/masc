open Alcotest
open Masc_tui_types

module Loader = Masc_tui_loader

let make_state () = create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

let refused status detail = Error (Http_refused { status; detail })

let workspace = { wi_base_path = "/fixture/a"; wi_masc_root = "/fixture/a/.masc" }

let close state outcome at =
  state.observer <- Observer_opening;
  Loader.record_observer_closed state ~workspace outcome ~reason:"retained failure" ~at

let test_retries_preserve_other_events () =
  let state = make_state () in
  Loader.add_event state "operator" "original action receipt";
  let original = state.events in
  for attempt = 1 to 12 do
    close state (refused 403 "denied") (float_of_int attempt)
  done;
  check int "one failure retained across reconnect attempts" 2 (List.length state.events);
  check bool "original action still retained" true
    (List.for_all (fun event -> List.mem event state.events) original);
  (match state.observer with
   | Observer_closed_before_answer { at; reason } ->
       check (float 0.) "latest failure observed" 12. at;
       check string "latest reason retained" "retained failure" reason
   | Observer_off | Observer_opening | Observer_live _ | Observer_closed_after_live _ ->
       fail "retry did not retain its failed observation")

let test_changed_failures_are_reported () =
  let state = make_state () in
  let cursor : Sse_wire.observer_cursor = { instance_id = "peer"; event_id = 1 } in
  let outcomes =
    [ refused 403 "denied"; refused 403 "credentials changed";
      refused 500 "credentials changed";
      Error (Transport_failed "credentials changed");
      Error (Invalid_handshake "credentials changed");
      Error (Retry_without_cursor (cursor, "no replay"));
      Error (Retry_without_cursor ({ cursor with event_id = 2 }, "no replay"));
      Ok () ]
  in
  List.iteri (fun index outcome ->
    close state outcome (float_of_int index);
    close state outcome (float_of_int index)) outcomes;
  check int "every distinct typed result retained once"
    (List.length outcomes) (List.length state.events)

let test_recovery_starts_a_new_outage () =
  let state = make_state () in
  let outcome = refused 403 "denied" in
  close state outcome 1.;
  Loader.record_observer_opened state ~session_id:"session" ~at:2.;
  check bool "actual open retires the prior outage" true
    (Option.is_none state.observer_last_close);
  let before = List.length state.events in
  state.observer <- Observer_live { session_id = "session"; since = 2.; events = 7 };
  Loader.record_observer_closed state ~workspace outcome ~reason:"new outage" ~at:3.;
  check int "same failure reported after recovery" (before + 1) (List.length state.events);
  (match state.observer with
   | Observer_closed_after_live { events; _ } ->
       check int "delivered count retained" 7 events
   | Observer_off | Observer_opening | Observer_live _ | Observer_closed_before_answer _ ->
       fail "live stream's close lost its delivered count")

let test_temporary_withdrawal_and_workspace_change () =
  let state = make_state () in
  let outcome = refused 409 "workspace unconfirmed" in
  close state outcome 1.;
  suspend_workspace_readings state;
  close state outcome 2.;
  check int "temporary withdrawal is the same outage" 1 (List.length state.events);
  let Workspace_authority previous = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (previous + 1);
  close state outcome 3.;
  check int "revalidating the same requested workspace is the same outage"
    1 (List.length state.events);
  let workspace = { wi_base_path = "/fixture/b"; wi_masc_root = "/fixture/b/.masc" } in
  Loader.record_observer_closed state ~workspace outcome ~reason:"other workspace" ~at:4.;
  check int "new requested workspace reports its own failure" 2 (List.length state.events)

let test_revalidation_does_not_refill_the_log () =
  let state = make_state () in
  Loader.add_event state "operator" "original action receipt";
  let original = state.events in
  for attempt = 1 to 12 do
    state.workspace_authority <- Workspace_authority attempt;
    close state (refused 409 "workspace mismatch") (float_of_int attempt)
  done;
  check int "same requested workspace does not refill the log" 2 (List.length state.events);
  check bool "operator receipt survives revalidation" true
    (List.for_all (fun event -> List.mem event state.events) original);
  let workspace = { wi_base_path = "/fixture/b"; wi_masc_root = "/fixture/b/.masc" } in
  Loader.record_observer_closed state ~workspace (refused 409 "workspace mismatch")
    ~reason:"other requested workspace" ~at:13.;
  check int "another requested workspace is a distinct event" 3 (List.length state.events)

let () =
  run "Observer session events"
    [ "outages",
      [ test_case "retries retain unrelated events" `Quick test_retries_preserve_other_events;
        test_case "changed failures remain observable" `Quick test_changed_failures_are_reported;
        test_case "recovery starts a new outage" `Quick test_recovery_starts_a_new_outage;
        test_case "workspace owns its outage" `Quick test_temporary_withdrawal_and_workspace_change;
        test_case "revalidation retains unrelated events" `Quick test_revalidation_does_not_refill_the_log ] ]
