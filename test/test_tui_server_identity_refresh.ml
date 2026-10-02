module Tui_decode = Masc.Tui_decode

let identity base_path : Tui_decode.server_identity =
  { Tui_decode.sid_version = "0.24.0"
  ; sid_binary_commit = "abc1234"
  ; sid_binary_commit_age_s = Some 10.
  ; sid_base_path = base_path
  ; sid_masc_root = base_path ^ "/.masc"
  ; sid_executable_in_worktree = Some false
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  }

let test_same_endpoint_restart_replaces_a_with_b () =
  let current = ref None in
  let apply reading =
    current := Masc_tui_types.server_identity_of_refresh reading
  in
  apply (Ok (identity "/a"));
  apply (Ok (identity "/b"));
  match !current with
  | None -> Alcotest.fail "a successful B probe removed the identity"
  | Some reading ->
    Alcotest.(check string) "current base path" "/b"
      reading.Tui_decode.sid_base_path

let test_failed_probe_is_unread_not_stale () =
  Alcotest.(check bool) "failed probe has no current identity" true
    (Option.is_none
       (Masc_tui_types.server_identity_of_refresh (Error "one failed tick")))

let test_workspace_identity_matches_canonical_paths () =
  let dir = Filename.temp_file "tui-workspace-identity-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  let alias = dir ^ "-alias" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove alias with Sys_error _ -> ());
      Unix.rmdir (Filename.concat dir ".masc");
      Unix.rmdir dir)
    (fun () ->
       Unix.symlink dir alias;
       Alcotest.(check bool) "same canonical base and runtime root retain request authority" true
         (Masc_tui_types.server_workspace_matches ~expected:(Some (identity alias))
            (Ok (identity dir)));
       match
         Masc_tui_types.workspace_identity_of_refresh
           ~local_base_path:alias
           (Ok (identity dir))
       with
       | Masc_tui_types.Workspace_identity_match -> ()
       | _ -> Alcotest.fail "canonical aliases did not match")

let test_workspace_identity_mismatch_keeps_both_paths () =
  match
    Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:"/workspace/local"
      (Ok (identity "/workspace/server"))
  with
  | Masc_tui_types.Workspace_identity_mismatch
      { local_base_path; server_base_path } ->
    Alcotest.(check string) "local path" "/workspace/local" local_base_path;
    Alcotest.(check string) "server path" "/workspace/server" server_base_path
  | _ -> Alcotest.fail "different workspaces were not blocked"

let test_detail_intents_wait_for_comparable_identity () =
  let state = Masc_tui_types.create_state ~workspace:"a"
    ~local_base_path:"/workspace/a" ~port:0 ~refresh_interval:0. () in
  let origin = identity "/workspace/a" in
  state.pending_detail_focus <- Some (origin, "same-keeper", Masc_tui_types.Detail_instructions);
  state.connector_unbind_offer_pending <- ["same-keeper"];
  state.connector_unbind_offer_origin <- Some origin;
  state.keeper_sandbox_logs_requested <- Some "same-keeper";
  state.keeper_sandbox_logs_origin <- Some origin;
  let apply = Masc_tui_types.reconcile_detail_intent_origins state in
  let retained label =
    Alcotest.(check bool) (label ^ " source-bound detail focus") true
      (state.pending_detail_focus = Some (origin, "same-keeper", Masc_tui_types.Detail_instructions));
    Alcotest.(check (list string)) (label ^ " connector intent")
      ["same-keeper"] state.connector_unbind_offer_pending;
    Alcotest.(check (option string)) (label ^ " Sandbox intent")
      (Some "same-keeper") state.keeper_sandbox_logs_requested;
    Alcotest.(check bool) (label ^ " origins remain bound") true
      (state.connector_unbind_offer_origin = Some origin
       && state.keeper_sandbox_logs_origin = Some origin)
  in
  apply (Error "health unavailable"); retained "failed probe";
  apply (Ok { origin with sid_base_path = "" }); retained "missing base";
  apply (Ok { origin with sid_masc_root = "" }); retained "missing root";
  apply (Ok { origin with sid_base_path = ""; sid_masc_root = "";
    sid_state_ready = Some false }); retained "booting unread";
  apply (Ok origin); retained "same workspace recovery";
  (* Same Keeper name and base, different runtime store: no inherited log
     request or post-action offer may become an action in that new store. *)
  apply (Ok { origin with sid_masc_root = "/workspace/a/another-masc-root" });
  Alcotest.(check bool) "foreign root retires detail focus" true
    (state.pending_detail_focus = None);
  Alcotest.(check (list string)) "foreign root clears connector intent"
    [] state.connector_unbind_offer_pending;
  Alcotest.(check (option string)) "foreign root clears Sandbox intent"
    None state.keeper_sandbox_logs_requested;
  Alcotest.(check bool) "foreign root retires both origins" true
    (state.connector_unbind_offer_origin = None && state.keeper_sandbox_logs_origin = None);
  apply (Ok origin);
  Alcotest.(check bool) "return to A does not recreate detail focus" true
    (state.pending_detail_focus = None);
  Alcotest.(check (option string)) "return to A does not recreate Sandbox intent"
    None state.keeper_sandbox_logs_requested

let test_same_base_with_different_masc_root_cannot_restore_inputs () =
  let a = identity "/workspace/shared" in
  let b = { a with sid_masc_root = "/workspace/other-cluster/.masc" } in
  (match Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:"/workspace/shared" (Ok b) with
   | Masc_tui_types.Workspace_identity_mismatch _ -> ()
   | _ -> Alcotest.fail "a different MASC root authorized local metadata");
  let key identity = Masc_tui_types.workspace_input_identity_of_server (Some identity) in
  let retained = [key a, "A's queued input and draft"] in
  Alcotest.(check (option string)) "B cannot restore A's retained input" None
    (List.assoc_opt (key b) retained);
  Alcotest.(check (option string)) "returning to A retains explicit resume"
    (Some "A's queued input and draft") (List.assoc_opt (key a) retained)

(* The keeper, task and log lists start empty and are read only once the server
   vouches for this workspace, so before that an empty list is not an empty
   workspace (#35747). *)
let test_local_rows_are_unread_until_the_workspace_is_read () =
  let state =
    Masc_tui_types.create_state ~workspace:"local"
      ~local_base_path:"/workspace/local" ~port:0 ~refresh_interval:0. ()
  in
  let page error =
    match Masc_tui_types.local_rows_page state ~error with
    | Masc_tui_types.Page_unread -> "unread"
    | Masc_tui_types.Page_failed -> "failed"
    | Masc_tui_types.Page_empty -> "empty"
  in
  Alcotest.(check string) "a fresh state has read nothing" "unread" (page None);
  state.Masc_tui_types.local_workspace <- Masc_tui_types.Local_workspace_read;
  Alcotest.(check string) "a read with no rows is empty" "empty" (page None);
  Alcotest.(check string) "a read with an error failed" "failed"
    (page (Some "keeper metadata unavailable"))

let test_request_authority_requires_complete_current_identity () =
  let before = identity "/a" in
  let accepts after =
    Masc_tui_types.server_workspace_matches ~expected:(Some before) after
  in
  Alcotest.(check bool) "same workspace" true (accepts (Ok before));
  Alcotest.(check bool) "dynamic health does not revoke" true
    (accepts (Ok { before with sid_uptime = Some "30s" }));
  Alcotest.(check bool) "different base" false (accepts (Ok (identity "/b")));
  Alcotest.(check bool) "different runtime root" false
    (accepts (Ok { before with sid_masc_root = "/a/other-root" }));
  Alcotest.(check bool) "booting successor" false
    (accepts (Ok { before with sid_state_ready = Some false }));
  Alcotest.(check bool) "unavailable successor" false (accepts (Error "unavailable"));
  Alcotest.(check bool) "no prior identity" false
    (Masc_tui_types.server_workspace_matches ~expected:None (Ok before));
  Alcotest.(check bool) "missing root cannot authorize" false
    (let incomplete = { before with sid_masc_root = "" } in
     Masc_tui_types.server_workspace_matches ~expected:(Some incomplete) (Ok incomplete))

let test_detail_focus_waits_for_authoritative_roster () =
  let open Masc_tui_types in
  let origin = identity "/workspace/a" in
  let keeper name : keeper = { k_origin = Tui_decode.Persisted_keeper; k_name = name;
    k_paused = false; k_identity = Error "not needed for navigation"; k_activity = None } in
  let suspended () =
    let state = create_state ~workspace:"local" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
    state.workspace_identity <- Workspace_identity_match;
    state.server_identity <- Some origin;
    state.local_workspace <- Local_workspace_read;
    state.keepers <- [keeper "other"; keeper "focused"];
    state.keeper_cursor <- 1;
    state.view <- Keepers Keeper_detail;
    state.detail_tab <- Detail_instructions;
    remember_keeper_detail_focus state;
    state.keepers <- [];
    state.keeper_cursor <- 0;
    state.server_identity <- None;
    state.workspace_identity <- Workspace_identity_unread;
    state.local_workspace <- Local_workspace_unread;
    state
  in
  let ready state keepers =
    state.server_identity <- Some origin;
    state.workspace_identity <- Workspace_identity_match;
    state.local_workspace <- Local_workspace_read;
    state.keepers <- keepers;
    (* Model the loader's list fallback after untrusted rows were cleared. *)
    state.view <- Keepers Keeper_list
  in
  let state = suspended () in
  reconcile_detail_intent_origins state (Ok {origin with sid_masc_root=""});
  Alcotest.(check bool) "incomplete identity cannot restore" false (restore_keeper_detail_focus state);
  Alcotest.(check int) "navigation retains no untrusted rows" 0 (List.length state.keepers);
  ready state [keeper "focused";keeper "other"];
  state.keepers_error <- Some "roster unavailable";
  Alcotest.(check bool) "failed roster cannot restore" false (restore_keeper_detail_focus state);
  state.keepers_error <- None;
  Alcotest.(check bool) "matching complete roster restores focus" true (restore_keeper_detail_focus state);
  Alcotest.(check bool) "name and tab survive reorder" true
    (state.view=Keepers Keeper_detail && state.keeper_cursor=0 && state.detail_tab=Detail_instructions);
  Alcotest.(check bool) "restoration is consumed once" false (restore_keeper_detail_focus state);
  let left = suspended () in
  ready left [keeper "focused"];
  left.view <- Overview;
  Alcotest.(check bool) "leaving fallback list prevents recovery navigation" false
    (restore_keeper_detail_focus left);
  Alcotest.(check bool) "explicit exit retires focus" true (left.detail_focus_recovery=None);
  let missing = suspended () in
  ready missing [keeper "other"];
  Alcotest.(check bool) "missing name cannot reopen another Keeper" false (restore_keeper_detail_focus missing);
  Alcotest.(check bool) "trusted absence retires intent" true (missing.detail_focus_recovery=None);
  let foreign = suspended () in
  reconcile_detail_intent_origins foreign (Ok {origin with sid_masc_root="/workspace/a/foreign"});
  ready foreign [keeper "focused"];
  Alcotest.(check bool) "foreign store retires intent even after returning" false (restore_keeper_detail_focus foreign)

let () =
  Alcotest.run "tui_server_identity_refresh"
    [ ( "server-identity-refresh"
      , [ Alcotest.test_case "detail focus waits for authoritative roster" `Quick
            test_detail_focus_waits_for_authoritative_roster
        ; Alcotest.test_case "same base and different MASC root retain separate inputs" `Quick
            test_same_base_with_different_masc_root_cannot_restore_inputs
        ; Alcotest.test_case "request authority requires complete current identity" `Quick
            test_request_authority_requires_complete_current_identity
        ; Alcotest.test_case "same endpoint replaces A with B" `Quick
            test_same_endpoint_restart_replaces_a_with_b
        ; Alcotest.test_case "failed probe is unread, not stale" `Quick
            test_failed_probe_is_unread_not_stale
        ; Alcotest.test_case "canonical aliases match" `Quick
            test_workspace_identity_matches_canonical_paths
        ; Alcotest.test_case "mismatch preserves both paths" `Quick
            test_workspace_identity_mismatch_keeps_both_paths
        ; Alcotest.test_case "detail intents wait for comparable identity" `Quick
            test_detail_intents_wait_for_comparable_identity
        ; Alcotest.test_case "local rows are unread until read" `Quick
            test_local_rows_are_unread_until_the_workspace_is_read
        ] )
    ]
