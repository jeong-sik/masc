open Alcotest
module T = Masc_tui_types
module C = Masc_tui_collab

let identity name : Masc.Tui_decode.server_identity =
  {sid_version = "test"; sid_binary_commit = "test"; sid_binary_commit_age_s = None;
   sid_base_path = "/fixture/" ^ name; sid_masc_root = "/fixture/" ^ name ^ "/.masc";
   sid_executable_in_worktree = None; sid_state_ready = Some true; sid_uptime = None;
   sid_sse_clients = None; sid_gc = None; sid_scheduler = None}
let current state name =
  state.T.server_identity <- Some (identity name);
  state.T.workspace_identity <- T.Workspace_identity_match
let fresh () =
  let state = T.create_state ~workspace:"test" ~port:8935 ~refresh_interval:2. () in
  current state "a";
  state
let admitted = function Ok request -> request | Error detail -> fail detail
let blocked state kind = check bool "no mutation is admitted" true (Result.is_error (T.begin_play_change state kind))
let unknown state = check bool "unknown outcome remains visible" true
  (match T.play_change_access state with C.Uncertain _ -> true | _ -> false)

let test_unknown_survives_withdrawal () =
  List.iter (fun kind ->
    let state = fresh () in
    let old = admitted (T.begin_play_change state kind) in
    T.withdraw_play_changes state;
    state.server_identity <- None;
    state.workspace_identity <- T.Workspace_identity_unread;
    blocked state (T.Issue_invite "same");
    current state "a";
    unknown state;
    blocked state (T.Revoke_invite "same");
    let view = C.write_access (C.create ()) (T.play_change_access state) in
    let view, read = C.loading view in
    let view = C.listed view read (Ok []) in
    let view, _ = C.key view "n" in
    check bool "an empty inventory cannot unlock an unknown write" false (C.text_input_active view);
    unknown state;
    check bool "a matching definitive receipt may settle its own request" true
      (T.finish_play_change state old T.Change_confirmed);
    ignore (admitted (T.begin_play_change state (T.Issue_invite "same"))))
    [T.Issue_invite "same"; T.Revoke_invite "same"]

let test_origin_and_explicit_resolution () =
  let state = fresh () in
  let old = admitted (T.begin_play_change state (T.Revoke_invite "same")) in
  ignore (T.finish_play_change state old T.Change_unknown);
  current state "b";
  let other = admitted (T.begin_play_change state (T.Issue_invite "same")) in
  check bool "a pending request cannot be manually cleared" true (Result.is_error (T.resolve_play_change state));
  ignore (T.finish_play_change state other T.Change_confirmed);
  current state "a";
  unknown state;
  check bool "explicit confirmation resolves the current origin" true (Result.is_ok (T.resolve_play_change state));
  let newer = admitted (T.begin_play_change state (T.Issue_invite "same")) in
  check bool "a retired receipt cannot settle the later issue" false (T.finish_play_change state old T.Change_confirmed);
  blocked state (T.Revoke_invite "same");
  check bool "the newer issue still owns settlement" true (T.finish_play_change state newer T.Change_confirmed)

let test_mismatch_blocks_form_and_dispatch () =
  let state = fresh () in
  current state "b";
  state.workspace_identity <- T.Workspace_identity_mismatch
    {local_base_path = "/fixture/a"; server_base_path = "/fixture/b"};
  List.iter (fun kind -> blocked state kind) [T.Issue_invite "same"; T.Revoke_invite "same"];
  let view = C.write_access (C.create ()) (T.play_change_access state) in
  let view, _ = C.key view "n" in
  check bool "mismatched authority cannot open a name field" false (C.text_input_active view);
  let form, _ = C.key (C.create ()) "n" in
  let form = C.write_access form (T.play_change_access state) in
  check bool "withdrawal closes an already open form" false (C.text_input_active form);
  let _, action = C.key form "enter" in
  check bool "a hidden form cannot issue after withdrawal" true (action = C.Stay);
  state.workspace_identity <- T.Workspace_identity_unread;
  blocked state (T.Revoke_invite "same")

let test_machine_authority_withdrawal () =
  let state = fresh () in
  state.machine_interaction <- T.Control_machine;
  state.msx_open <- true;
  state.msx_menu_open <- true;
  state.msx_live_in_flight <- Some {T.live_view = ref (); live_port = 8935};
  T.withdraw_machine_control state;
  check bool "control requires fresh operator intent" true (state.machine_interaction = T.Observe_machine);
  check bool "the old view and its menu are closed" true (not state.msx_open && not state.msx_menu_open);
  check bool "the old read cannot own a new screen" true (Option.is_none state.msx_live_in_flight)

let () = run "Play workspace authority" ["lifecycle", [
  test_case "unknown issue and revoke survive withdrawal and inventory" `Quick test_unknown_survives_withdrawal;
  test_case "origins, explicit resolution and stale receipts" `Quick test_origin_and_explicit_resolution;
  test_case "unverified authority blocks forms and dispatch" `Quick test_mismatch_blocks_form_and_dispatch;
  test_case "machine control ends at authority withdrawal" `Quick test_machine_authority_withdrawal;
]]
