(* The runtime.toml pane's removal screen, driven the way the key loop drives
   it: one decoded key at a time, then the file as the server holds it. *)

module S = Masc_tui_runtime_account_removal

let fixture =
  {|[runtime]
default = "codex_subscription.gpt-5.6"

[runtime.lanes.coding]
candidates = ["codex_acct1.gpt-5.6", "codex_subscription.gpt-5.6"]

[runtime.assignments]
fixture_remove_keeper = "codex_acct1.gpt-5.6"

[providers.codex_subscription]
display-name = "Codex"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true

[providers.codex_acct1]
display-name = "Codex · account1\u001b[31m red"
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/home/op/.codex-account1"

[models."gpt-5.6"]
api-name = "gpt-5.6"
max-context = 272000
tools-support = true

[codex_subscription."gpt-5.6"]

[codex_acct1."gpt-5.6"]
|}

let width_80 = Masc_tui_frame.inner_width ~cols:80

let contains text row =
  let n = String.length text in
  let rec at i = i + n <= String.length row && (String.sub row i n = text || at (i + 1)) in
  at 0

let rows screen = S.rows ~width:width_80 screen
let mentions text screen = List.exists (contains text) (rows screen)

let opened ?(text = fixture) () =
  match S.open_on text with
  | Ok screen -> screen
  | Error reason -> Alcotest.failf "the screen did not open: %s" reason

let choosing = function
  | S.Choosing screen -> screen
  | S.Cancelled -> Alcotest.fail "the screen closed"
  | S.Submitted _ -> Alcotest.fail "the screen submitted"

let press screen keys = List.fold_left (fun screen key -> choosing (S.key screen key)) screen keys

(* The second account, the one the fixture routes a lane and a keeper to. *)
let on_the_second () = press (opened ()) [ "right" ]

let submitted screen =
  match S.key screen "\r" with
  | S.Submitted screen -> screen
  | S.Choosing _ -> Alcotest.fail "enter did not submit"
  | S.Cancelled -> Alcotest.fail "enter closed the screen"

let test_the_screen_lists_what_the_removal_changes () =
  let screen = on_the_second () in
  Alcotest.(check string) "the account" "codex_acct1" (S.chosen screen);
  List.iter
    (fun text -> Alcotest.(check bool) ("names " ^ text) true (mentions text screen))
    [ "[providers.codex_acct1]"
    ; "[codex_acct1.\"gpt-5.6\"]"
    ; "lane coding"
    ; "keeper fixture_remove_keeper"
    ; "/home/op/.codex-account1"
    ];
  List.iter
    (fun row ->
      if Masc_tui_message_layout.display_width row > width_80
      then Alcotest.failf "a row is wider than the pane: %S" row)
    (List.filter (fun row -> not (contains "\xe2\x80\xb9" row)) (rows screen))

let test_enter_removes_what_was_shown () =
  let screen = submitted (on_the_second ()) in
  match S.remove_on screen fixture with
  | Ok { Runtime_account_removal.text; _ } ->
    Alcotest.(check bool) "the provider is gone" false (contains "[providers.codex_acct1]" text)
  | Error screen -> Alcotest.failf "refused: %s" (String.concat " / " (rows screen))

(* A keeper assigned to the account after the screen opened is a change the
   operator did not see, so nothing is saved until it is shown. *)
let test_a_file_changed_meanwhile_is_shown_again () =
  let screen = submitted (on_the_second ()) in
  let current =
    let marker = "fixture_remove_keeper = \"codex_acct1.gpt-5.6\"\n" in
    let at = Str.search_forward (Str.regexp_string marker) fixture 0 + String.length marker in
    String.sub fixture 0 at ^ "later = \"codex_acct1.gpt-5.6\"\n"
    ^ String.sub fixture at (String.length fixture - at)
  in
  match S.remove_on screen current with
  | Ok _ -> Alcotest.fail "a removal the operator did not see was saved"
  | Error screen ->
    Alcotest.(check bool) "the new assignment is shown" true (mentions "keeper later" screen);
    Alcotest.(check bool) "with a notice saying why" true
      (List.exists (String.starts_with ~prefix:"  ! ") (rows screen));
    (match S.remove_on (submitted screen) current with
     | Ok _ -> ()
     | Error screen -> Alcotest.failf "refused: %s" (String.concat " / " (rows screen)))

let test_a_refused_removal_does_not_submit () =
  let screen = opened () in
  Alcotest.(check string) "the first account" "codex_subscription" (S.chosen screen);
  Alcotest.(check bool) "the default names it" true (mentions "[runtime].default" screen);
  ignore (choosing (S.key screen "\r"))

let test_esc_abandons_and_nothing_is_typed () =
  let screen = on_the_second () in
  Alcotest.(check (list string)) "a letter changes nothing" (rows screen)
    (rows (press screen [ "x"; "q"; "tab" ]));
  match S.key screen "esc" with
  | S.Cancelled -> ()
  | S.Choosing _ | S.Submitted _ -> Alcotest.fail "esc did not close the screen"

let test_a_name_from_the_file_cannot_colour_the_pane () =
  let screen = on_the_second () in
  Alcotest.(check bool) "no escape reaches the pane" false
    (List.exists (fun row -> String.contains row '\027') (rows screen))

let test_a_file_with_no_account_has_nothing_to_remove () =
  match
    S.open_on
      "[providers.ollama]\nprotocol = \"ollama-http\"\nendpoint = \"http://localhost:11434\"\n"
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "a file with no official client opened the screen"

let () =
  Alcotest.run "tui_runtime_account_removal"
    [ ( "removal"
      , [ Alcotest.test_case "the screen lists what the removal changes" `Quick
            test_the_screen_lists_what_the_removal_changes
        ; Alcotest.test_case "enter removes what was shown" `Quick
            test_enter_removes_what_was_shown
        ; Alcotest.test_case "a file changed meanwhile is shown again" `Quick
            test_a_file_changed_meanwhile_is_shown_again
        ; Alcotest.test_case "a refused removal does not submit" `Quick
            test_a_refused_removal_does_not_submit
        ; Alcotest.test_case "esc abandons and nothing is typed" `Quick
            test_esc_abandons_and_nothing_is_typed
        ; Alcotest.test_case "a name from the file cannot colour the pane" `Quick
            test_a_name_from_the_file_cannot_colour_the_pane
        ; Alcotest.test_case "a file with no account has nothing to remove" `Quick
            test_a_file_with_no_account_has_nothing_to_remove
        ] )
    ]
