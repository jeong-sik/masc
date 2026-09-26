(* What the Keeper Runs tab knows about the retained runs. A failed read left
   the tab on "Loading Fusion runs..." for good, and a failed refresh has to
   keep the rows the tab already drew rather than empty it: both are states of
   the one [Masc_tui_fetched] reading the Fusion list holds. *)

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
  | Fetched.Stale (runs, detail) ->
      Printf.sprintf "stale: %d runs, %s" (List.length runs) detail
  | Fetched.Ready runs -> Printf.sprintf "ready: %d runs" (List.length runs)

let check name expected state =
  Alcotest.(check string) name expected (describe (Types.keeper_runs_view state))

let failure = "fusion runs load failed: HTTP 503"

(* The transitions the launcher and the answer handler make. *)
let ask state =
  match Fetched.start ~equal:Unit.equal state.Types.fusion_runs ~key:() with
  | Fetched.Already_loading -> Alcotest.fail "a list read is already in flight"
  | Fetched.Started (next, request) ->
      state.Types.fusion_runs <- next;
      request

let answer state request result =
  state.Types.fusion_runs <-
    Fetched.complete ~equal:Unit.equal state.Types.fusion_runs request result

let test_never_asked () = check "no request and no answer" "absent" (fresh ())

let test_in_flight () =
  let state = fresh () in
  ignore (ask state);
  check "asked, no answer yet" "loading" state

let test_failed_read () =
  let state = fresh () in
  answer state (ask state) (Error failure);
  check "the failure, not a loading row" ("failed: " ^ failure) state

let test_retry_after_failure () =
  let state = fresh () in
  answer state (ask state) (Error failure);
  ignore (ask state);
  check "a retry with nothing read is loading" "loading" state

let test_rows_kept_on_failure () =
  let state = fresh () in
  answer state (ask state) (Ok snapshot);
  answer state (ask state) (Error failure);
  check "held rows carry the failure" ("stale: 0 runs, " ^ failure) state

let test_retry_after_stale () =
  let state = fresh () in
  answer state (ask state) (Ok snapshot);
  answer state (ask state) (Error failure);
  let retry = ask state in
  check "a retry does not make held rows fresh" ("stale: 0 runs, " ^ failure) state;
  answer state retry (Ok snapshot);
  check "the next answer does" "ready: 0 runs" state

let test_rows_answered () =
  let state = fresh () in
  answer state (ask state) (Ok snapshot);
  check "an answer with no failure" "ready: 0 runs" state

let () =
  Alcotest.run "tui_keeper_runs_view"
    [ ( "keeper runs view"
      , [ Alcotest.test_case "never asked" `Quick test_never_asked
        ; Alcotest.test_case "in flight" `Quick test_in_flight
        ; Alcotest.test_case "failed read" `Quick test_failed_read
        ; Alcotest.test_case "retry after failure" `Quick test_retry_after_failure
        ; Alcotest.test_case "rows kept on failure" `Quick test_rows_kept_on_failure
        ; Alcotest.test_case "retry after stale" `Quick test_retry_after_stale
        ; Alcotest.test_case "rows answered" `Quick test_rows_answered
        ] )
    ]
