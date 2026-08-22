open Alcotest

module Detail = Masc_tui_board_detail

let started = function
  | Detail.Started (state, request) -> state, request
  | Detail.Already_loading -> fail "expected a new Board detail request"

let check_absent label state post_id =
  match Detail.view_for state ~post_id with
  | Detail.Absent -> ()
  | Detail.Loading | Detail.Ready _ | Detail.Failed _ -> fail label

let check_loading label state post_id =
  match Detail.view_for state ~post_id with
  | Detail.Loading -> ()
  | Detail.Absent | Detail.Ready _ | Detail.Failed _ -> fail label

let check_ready label expected state post_id =
  match Detail.view_for state ~post_id with
  | Detail.Ready value -> check string label expected value
  | Detail.Absent | Detail.Loading | Detail.Failed _ -> fail label

let check_failed label expected state post_id =
  match Detail.view_for state ~post_id with
  | Detail.Failed error -> check string label expected error
  | Detail.Absent | Detail.Loading | Detail.Ready _ -> fail label

let test_post_switch_isolates_detail_and_rejects_late_completion () =
  check_absent "initial detail is absent" Detail.initial "A";
  let loading_a, request_a = Detail.start Detail.initial ~post_id:"A" |> started in
  check_loading "A starts loading" loading_a "A";
  (match Detail.start loading_a ~post_id:"A" with
   | Detail.Already_loading -> ()
   | Detail.Started _ -> fail "duplicate A load was not suppressed");
  let ready_a = Detail.complete loading_a request_a (Ok "A comments") in
  check_ready "A becomes ready" "A comments" ready_a "A";

  let loading_b, request_b = Detail.start ready_a ~post_id:"B" |> started in
  check_loading "B starts loading" loading_b "B";
  check_absent "A detail is not projected for B" loading_b "A";
  let failed_b = Detail.complete loading_b request_b (Error "B failed") in
  check_failed "B failure remains visible" "B failed" failed_b "B";
  let after_late_a = Detail.complete failed_b request_a (Ok "late A") in
  check_failed "late A cannot replace B failure" "B failed" after_late_a "B"

let test_clear_and_reopen_rejects_same_post_aba () =
  let loading_a1, request_a1 = Detail.start Detail.initial ~post_id:"A" |> started in
  let cleared = Detail.clear loading_a1 in
  check_absent "clear removes the visible A projection" cleared "A";
  let loading_a2, request_a2 = Detail.start cleared ~post_id:"A" |> started in
  check bool "reopened A receives a fresh request" false
    (Detail.same_request request_a1 request_a2);
  let after_late_a1 = Detail.complete loading_a2 request_a1 (Ok "old A") in
  check_loading "old A completion cannot settle reopened A" after_late_a1 "A";
  let ready_a2 = Detail.complete after_late_a1 request_a2 (Ok "new A") in
  check_ready "new A completion settles reopened A" "new A" ready_a2 "A"

let test_retry_after_failure_uses_a_new_generation () =
  let loading, request1 = Detail.start Detail.initial ~post_id:"B" |> started in
  let failed = Detail.complete loading request1 (Error "first failure") in
  let retrying, request2 = Detail.start failed ~post_id:"B" |> started in
  check bool "retry receives a fresh request" false
    (Detail.same_request request1 request2);
  let stale = Detail.complete retrying request1 (Error "late failure") in
  check_loading "late failure cannot settle retry" stale "B";
  let ready = Detail.complete stale request2 (Ok "fresh B") in
  check_ready "retry can succeed" "fresh B" ready "B"

let () =
  run "tui_board_detail"
    [ ( "generation-aware projection"
      , [ test_case "post switch and late completion" `Quick
            test_post_switch_isolates_detail_and_rejects_late_completion
        ; test_case "clear and same-post ABA" `Quick
            test_clear_and_reopen_rejects_same_post_aba
        ; test_case "retry generation" `Quick
            test_retry_after_failure_uses_a_new_generation
        ] )
    ]
