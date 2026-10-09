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
let fresh local_base_path =
  let state = T.create_state ~workspace:"test" ~local_base_path ~port:8935 ~refresh_interval:2. () in
  current state "a";
  state
let admitted = function Ok request -> request | Error detail -> fail detail
let blocked state kind = check bool "no mutation is admitted" true (Result.is_error (T.begin_play_change state kind))
let unknown state = check bool "unknown outcome remains visible" true
  (match T.play_change_access state with C.Uncertain _ -> true | _ -> false)

let with_workspace test () =
  let base = Filename.temp_file "masc-play-recovery-" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> test base)

let test_unknown_survives_withdrawal base =
  List.iter (fun kind ->
    let state = fresh base in
    let old = admitted (T.begin_play_change state kind) in
    check bool "the HTTP request starts before withdrawal" true (T.dispatch_play_change state old);
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
    let next = admitted (T.begin_play_change state (T.Issue_invite "same")) in
    ignore (T.finish_play_change state next T.Change_confirmed))
    [T.Issue_invite "same"; T.Revoke_invite "same"]

let test_origin_and_explicit_resolution base =
  let state = fresh base in
  let old = admitted (T.begin_play_change state (T.Revoke_invite "same")) in
  ignore (T.finish_play_change state old T.Change_unknown);
  current state "b";
  let other = admitted (T.begin_play_change state (T.Issue_invite "same")) in
  check bool "a pending request cannot be manually cleared" true
    (Result.is_error (T.resolve_play_change state ~request_id:other.change_id));
  ignore (T.finish_play_change state other T.Change_confirmed);
  current state "a";
  unknown state;
  check bool "explicit confirmation resolves the current origin" true
    (Result.is_ok (T.resolve_play_change state ~request_id:old.change_id));
  let newer = admitted (T.begin_play_change state (T.Issue_invite "same")) in
  check bool "a retired receipt cannot settle the later issue" false (T.finish_play_change state old T.Change_confirmed);
  blocked state (T.Revoke_invite "same");
  check bool "the newer issue still owns settlement" true (T.finish_play_change state newer T.Change_confirmed)

let test_mismatch_blocks_form_and_dispatch base =
  let state = fresh base in
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

let test_machine_authority_withdrawal base =
  let state = fresh base in
  state.machine_interaction <- T.Control_machine;
  state.msx_open <- true;
  state.msx_menu_open <- true;
  state.msx_live_in_flight <- Some {T.live_view = ref (); live_port = 8935};
  T.withdraw_machine_control state;
  check bool "control requires fresh operator intent" true (state.machine_interaction = T.Observe_machine);
  check bool "the old view and its menu are closed" true (not state.msx_open && not state.msx_menu_open);
  check bool "the old read cannot own a new screen" true (Option.is_none state.msx_live_in_flight)

let test_unknown_survives_restart base =
  List.iter (fun kind ->
    let original = fresh base in
    let old = admitted (T.begin_play_change original kind) in
    (* No completion runs in the original process: the server may still hold
       its POST. Inventory and a new TUI process cannot certify settlement. *)
    let restarted = fresh base in
    unknown restarted;
    blocked restarted (T.Issue_invite "same");
    blocked restarted (T.Revoke_invite "same");
    current restarted "b";
    let other = admitted (T.begin_play_change restarted (T.Issue_invite "same")) in
    ignore (T.finish_play_change restarted other T.Change_confirmed);
    current restarted "a";
    unknown restarted;
    check bool "operator reconciliation is durable" true
      (Result.is_ok (T.resolve_play_change restarted ~request_id:old.change_id));
    let resumed = fresh base in
    let next = admitted (T.begin_play_change resumed (T.Issue_invite "same")) in
    ignore (T.finish_play_change original old T.Change_confirmed);
    let third = fresh base in
    unknown third;
    blocked third (T.Revoke_invite "same");
    ignore (T.finish_play_change resumed next T.Change_confirmed);
    check bool "settled request stays settled after restart" true
      (T.play_change_access (fresh base) = C.Writable))
    [T.Issue_invite "same"; T.Revoke_invite "same"]

let test_unreadable_recovery_refuses_dispatch base =
  let state = fresh base in
  let request = admitted (T.begin_play_change state (T.Revoke_invite "same")) in
  ignore (T.finish_play_change state request T.Change_confirmed);
  let oc = open_out_gen [Open_append; Open_binary] 0o600 (T.play_pending_path state) in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> output_string oc "{torn");
  let restarted = fresh base in
  blocked restarted (T.Issue_invite "same");
  check bool "corrupt storage is not a writable empty store" true
    (match T.play_change_access restarted with C.Read_only _ -> true | _ -> false)

let test_resolution_cannot_clear_another_process_request base =
  let original = fresh base in
  let old = admitted (T.begin_play_change original (T.Issue_invite "same")) in
  check bool "the original mutation starts" true (T.dispatch_play_change original old);
  let observer = fresh base in
  let view = C.write_access (C.create ()) (T.play_change_access observer) in
  let view, _ = C.key view "u" in
  ignore (T.finish_play_change original old T.Change_confirmed);
  let newer = admitted (T.begin_play_change original (T.Revoke_invite "same")) in
  check bool "the replacement mutation starts" true (T.dispatch_play_change original newer);
  let request_id = match snd (C.key view "enter") with
    | C.Resolve_unknown request_id -> request_id | _ -> fail "expected a captured confirmation" in
  check string "confirmation still belongs to the old request" old.change_id request_id;
  check bool "a fresh journal read cannot retarget the confirmation" true
    (Result.is_error (T.resolve_play_change observer ~request_id));
  unknown (fresh base);
  blocked (fresh base) (T.Issue_invite "same");
  ignore (T.finish_play_change original newer T.Change_confirmed)

let test_pre_dispatch_failure_releases_guard base =
  List.iter (fun kind ->
    let state = fresh base in
    let request = admitted (T.begin_play_change state kind) in
    check bool "preparation has not dispatched an HTTP mutation" false
      (T.play_change_dispatched state request);
    ignore (T.finish_play_change state request T.Change_confirmed);
    check bool "a failed launch leaves no guard across restart" true
      (T.play_change_access (fresh base) = C.Writable);
    let request = admitted (T.begin_play_change state kind) in
    (* The failed identity probe withdraws authority before its completion can
       be consumed. No later completion is needed to settle this preparation. *)
    T.withdraw_play_changes state;
    check bool "a withdrawn preparation cannot dispatch later" false
      (T.dispatch_play_change state request);
    check bool "pre-dispatch authority failure leaves no durable uncertainty" true
      (T.play_change_access (fresh base) = C.Writable))
    [T.Issue_invite "same"; T.Revoke_invite "same"]

let test_cross_process_settlement_keeps_the_live_response_owner base =
  List.iter (fun kind ->
    let original = fresh base in
    let sent = admitted (T.begin_play_change original kind) in
    check bool "the original mutation starts" true (T.dispatch_play_change original sent);
    (* Another TUI verifies the request finished and settles it while this
       process has not consumed the response yet. *)
    let observer = fresh base in
    check bool "the other TUI resolves the request" true
      (Result.is_ok (T.resolve_play_change observer ~request_id:sent.change_id));
    (* Any access refresh rereads the journal before the response is consumed. *)
    check bool "the sender still waits for its own response" true
      (match T.play_change_access original with C.Pending _ -> true | _ -> false);
    check bool "the response is still owned by its sender" true
      (T.finish_play_change original sent T.Change_confirmed);
    check bool "the settled journal admits the next change" true
      (T.play_change_access original = C.Writable);
    check bool "nothing is left for a restarted TUI" true (T.play_change_access (fresh base) = C.Writable))
    [T.Issue_invite "same"; T.Revoke_invite "same"]

let () = run "Play workspace authority" ["lifecycle", [
  test_case "unknown issue and revoke survive withdrawal and inventory" `Quick (with_workspace test_unknown_survives_withdrawal);
  test_case "origins, explicit resolution and stale receipts" `Quick (with_workspace test_origin_and_explicit_resolution);
  test_case "unverified authority blocks forms and dispatch" `Quick (with_workspace test_mismatch_blocks_form_and_dispatch);
  test_case "machine control ends at authority withdrawal" `Quick (with_workspace test_machine_authority_withdrawal);
  test_case "unknown changes survive restarts and late receipts" `Quick (with_workspace test_unknown_survives_restart);
  test_case "unreadable recovery refuses dispatch" `Quick (with_workspace test_unreadable_recovery_refuses_dispatch);
  test_case "confirmation cannot settle another process's replacement request" `Quick (with_workspace test_resolution_cannot_clear_another_process_request);
  test_case "pre-dispatch failures release durable mutation admission" `Quick (with_workspace test_pre_dispatch_failure_releases_guard);
  test_case "cross-process settlement keeps the live response owner" `Quick (with_workspace test_cross_process_settlement_keeps_the_live_response_owner);
]]
