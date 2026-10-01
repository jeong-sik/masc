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
  let alias = dir ^ "-alias" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove alias with Sys_error _ -> ());
      Unix.rmdir dir)
    (fun () ->
       Unix.symlink dir alias;
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
  state.connector_unbind_offer_pending <- ["same-keeper"];
  state.connector_unbind_offer_origin <- Some origin;
  state.keeper_sandbox_logs_requested <- Some "same-keeper";
  state.keeper_sandbox_logs_origin <- Some origin;
  let apply = Masc_tui_types.reconcile_detail_intent_origins state in
  let retained label =
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
  Alcotest.(check (list string)) "foreign root clears connector intent"
    [] state.connector_unbind_offer_pending;
  Alcotest.(check (option string)) "foreign root clears Sandbox intent"
    None state.keeper_sandbox_logs_requested;
  Alcotest.(check bool) "foreign root retires both origins" true
    (state.connector_unbind_offer_origin = None && state.keeper_sandbox_logs_origin = None);
  apply (Ok origin);
  Alcotest.(check (option string)) "return to A does not recreate Sandbox intent"
    None state.keeper_sandbox_logs_requested

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

let () =
  Alcotest.run "tui_server_identity_refresh"
    [ ( "server-identity-refresh"
      , [ Alcotest.test_case "same endpoint replaces A with B" `Quick
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
