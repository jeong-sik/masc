(* What the Keeper Runs tab knows about the retained runs. A failed read left
   the tab on "Loading Fusion runs..." for good: it looked at the snapshot and
   never at [fusion_error], which only the Fusion surface drew. *)

module Types = Masc_tui_types
module Fetched = Masc_tui_fetched

let fresh () =
  Types.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2.0 ()

let snapshot : Masc.Tui_decode.fusion_snapshot =
  { fus_generated_at = "2026-09-13T00:00:00Z"
  ; fus_runs = []
  ; fus_replay = Fusion_not_replayed
  ; fus_historical_evidence = []
  }

let describe = function
  | Fetched.Absent -> "absent"
  | Fetched.Loading -> "loading"
  | Fetched.Failed detail -> "failed: " ^ detail
  | Fetched.Ready (runs, stale) ->
      Printf.sprintf "ready: %d runs, stale: %s" (List.length runs)
        (Option.value ~default:"none" stale)

let check name expected state =
  Alcotest.(check string) name expected (describe (Types.keeper_runs_view state))

let failure = "fusion runs load failed: HTTP 503"

let test_never_asked () = check "no request and no answer" "absent" (fresh ())

let test_in_flight () =
  let state = fresh () in
  state.Types.fusion_runs_inflight <- Some 1;
  check "asked, no answer yet" "loading" state

let test_failed_read () =
  let state = fresh () in
  state.Types.fusion_error <- Some failure;
  check "the failure, not a loading row" ("failed: " ^ failure) state

let test_retry_after_failure () =
  let state = fresh () in
  state.Types.fusion_error <- Some failure;
  state.Types.fusion_runs_inflight <- Some 2;
  check "a retry in flight is loading" "loading" state

let test_rows_kept_on_failure () =
  let state = fresh () in
  state.Types.fusion_runs <- Some snapshot;
  state.Types.fusion_error <- Some failure;
  check "held rows carry the failure" ("ready: 0 runs, stale: " ^ failure) state

let test_rows_answered () =
  let state = fresh () in
  state.Types.fusion_runs <- Some snapshot;
  check "an answer with no failure" "ready: 0 runs, stale: none" state

let () =
  Alcotest.run "tui_keeper_runs_view"
    [ ( "keeper runs view"
      , [ Alcotest.test_case "never asked" `Quick test_never_asked
        ; Alcotest.test_case "in flight" `Quick test_in_flight
        ; Alcotest.test_case "failed read" `Quick test_failed_read
        ; Alcotest.test_case "retry after failure" `Quick test_retry_after_failure
        ; Alcotest.test_case "rows kept on failure" `Quick test_rows_kept_on_failure
        ; Alcotest.test_case "rows answered" `Quick test_rows_answered
        ] )
    ]
