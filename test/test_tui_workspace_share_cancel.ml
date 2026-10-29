(* Exercise the real workspace result/job cancellation boundary with a held
   preflight or a held effect. The held effect is not an HTTP server. *)
open Alcotest
module Results = Masc_tui_workspace_result
module Job = Masc_tui_workspace_job
module Types = Masc_tui_types
module Attempt = Masc_tui_artifact_share_attempt

type receipt = Not_sent | Unknown | Completed

let state () = Types.create_state ~workspace:"share-cancel" ~port:0 ~refresh_interval:0. ()
let classify attempt = if Attempt.dispatched attempt then Unknown else Not_sent
let take_one results = match Results.take_ready results with
  | [{ Results.message; _ }] ->
      check bool "the result is published only once" true (Results.take_ready results = []);
      message
  | _ -> fail "expected exactly one share receipt"
let launch state results ~attempt ?key ?observe_job perform =
  Results.launch ?key ?observe_job ~observation:true state ~results
    ~boundary_error:(fun _ -> classify attempt)
    ~cancelled_by:(fun () -> classify attempt)
    ~deliver:(function Ok () -> Completed | Error receipt -> receipt)
    perform

let no_switch () =
  let snapshot = Eio_context.snapshot_state () in
  Fun.protect ~finally:(fun () -> Eio_context.restore_state snapshot) @@ fun () ->
  Eio_context.For_testing.clear_root_switch ();
  check bool "there is no operation switch" true (Option.is_none (Eio_context.get_switch_opt ()));
  let results = Results.create () and attempt = Attempt.create () and entered = ref false in
  launch (state ()) results ~attempt (fun () -> entered := true; Ok ());
  check bool "no producer entered" false !entered;
  check bool "no switch is not sent" true (take_one results = Not_sent);
  Results.close results

let cancelled_before_dispatch () =
  Eio.Switch.run @@ fun outer -> Eio_context.with_turn_switch outer @@ fun () ->
  let results = Results.create () and attempt = Attempt.create () and entered = ref false in
  let exception Stop_before_dispatch in
  let propagated = try
    Eio.Cancel.sub (fun context -> Eio.Switch.run (fun cancelled_switch ->
      Eio_context.with_turn_switch cancelled_switch (fun () ->
        Eio.Cancel.cancel context Stop_before_dispatch;
        launch (state ()) results ~attempt (fun () -> entered := true; Ok ()))));
    false
  with Eio.Cancel.Cancelled Stop_before_dispatch -> true in
  check bool "cancellation propagates" true propagated;
  check bool "the producer never entered" false !entered;
  check bool "pre-dispatch cancellation is not sent" true (take_one results = Not_sent);
  Results.close results

let cancelled_after_entry ~after_dispatch () =
  Eio.Switch.run @@ fun sw -> Eio_context.with_turn_switch sw @@ fun () ->
  let state = state () and results = Results.create () and attempt = Attempt.create () in
  let entered, enter = Eio.Promise.create () and released, release = Eio.Promise.create () in
  let gate, _ = Eio.Promise.create () and key = ref () in
  let observe_job = function
    | Job.Registration_released -> ignore (Eio.Promise.try_resolve release ())
    | Job.Cancellation_requested -> () in
  let hold () = Eio.Promise.resolve enter (); Eio.Promise.await gate; Ok () in
  launch state results ~attempt ~key ~observe_job (fun () ->
    let preflight () = if after_dispatch then Ok () else hold () in
    let send () = if after_dispatch then hold () else fail "cancelled preflight sent a POST" in
    match Attempt.perform attempt ~preflight ~send with
    | Attempt.Not_sent _ -> Error Not_sent
    | Attempt.Sent (Ok ()) -> Ok ()
    | Attempt.Sent (Error _) -> Error Unknown);
  Eio.Promise.await entered;
  Job.cancel_observation state ~key;
  Eio.Promise.await released;
  let expected = if after_dispatch then Unknown else Not_sent in
  check bool "receipt reflects whether the effect could have started" true (take_one results = expected);
  Results.close results

let () = Eio_main.run @@ fun _ ->
  run "TUI share cancellation boundaries" ["workspace result", [
    test_case "no switch" `Quick no_switch;
    test_case "cancelled before dispatch" `Quick cancelled_before_dispatch;
    test_case "cancelled during preflight" `Quick (cancelled_after_entry ~after_dispatch:false);
    test_case "cancelled after effect entry" `Quick (cancelled_after_entry ~after_dispatch:true)
  ]]
