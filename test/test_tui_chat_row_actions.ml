open Alcotest
module Actions = Masc_tui_chat_row_actions

let same_scope (workspace, reading) (other_workspace, other_reading) =
  workspace = other_workspace && reading == other_reading

let test_presented_rows_keep_their_owner () =
  let reading = ref () in
  let scope = 1, reading in
  let shown = Actions.of_rows ~scope ~keeper:"alpha" [ 4; 7 ] in
  let contains ?(scope = scope) ?(keeper = Some "alpha") row =
    Actions.contains ~same_scope ~scope ~keeper ~row shown
  in
  check bool "the first action is reachable" true (contains 4);
  check bool "the other action is reachable" true (contains 7);
  check bool "a different row is inert" false (contains 5);
  check bool "another Keeper cannot use it" false (contains ~keeper:(Some "beta") 4);
  check bool "no selected Keeper cannot use it" false (contains ~keeper:None 4);
  check bool "another workspace cannot use it" false (contains ~scope:(2, reading) 4);
  check bool "a new read epoch cannot use it" false (contains ~scope:(1, ref ()) 4);
  check bool "an equal frame is the same authority" true
    (Actions.equal ~same_scope shown (Actions.of_rows ~scope ~keeper:"alpha" [ 4; 7 ]));
  check bool "a new epoch changes hidden authority" false
    (Actions.equal ~same_scope shown (Actions.of_rows ~scope:(1, ref ()) ~keeper:"alpha" [ 4; 7 ]));
  check bool "no rows means no action" true
    (Actions.equal ~same_scope Actions.empty (Actions.of_rows ~scope ~keeper:"alpha" []))

let test_approval_without_actionable_history_is_frame_owned () =
  let scope = 1, ref () in
  let approval : _ Actions.approval =
    { scope; keeper = "alpha"; request_id = "request-a"
    ; tool_call_id = "call-a"; approval_id = "waiter-a" }
  in
  let shown = Actions.with_approval approval Actions.empty in
  check bool "the pending prompt does not need a history-row action" true
    (Option.is_some (Actions.approval shown));
  check bool "a prompt adds no clickable history rows" false
    (Actions.contains ~same_scope ~scope ~keeper:(Some "alpha") ~row:4 shown);
  let replacement =
    Actions.with_approval { approval with approval_id = "waiter-b" } Actions.empty
  in
  check bool "identical rows with another waiter change frame authority" false
    (Actions.equal ~same_scope shown replacement);
  check bool "a hidden prompt has no receipt" true
    (Option.is_none (Actions.approval Actions.empty))

let () =
  run "tui_chat_row_actions"
    [ "presented", [ test_case "rows retain scope and Keeper" `Quick test_presented_rows_keep_their_owner;
        test_case "pending prompt belongs to its frame" `Quick test_approval_without_actionable_history_is_frame_owned ] ]
