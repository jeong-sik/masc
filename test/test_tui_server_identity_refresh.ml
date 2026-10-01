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

let () =
  Alcotest.run "tui_server_identity_refresh"
    [ ( "server-identity-refresh"
      , [ Alcotest.test_case "same base and different MASC root retain separate inputs" `Quick
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
        ; Alcotest.test_case "local rows are unread until read" `Quick
            test_local_rows_are_unread_until_the_workspace_is_read
        ] )
    ]
