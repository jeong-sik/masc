module Tui_decode = Masc.Tui_decode

let identity base_path : Tui_decode.server_identity =
  { Tui_decode.sid_version = "0.24.0"
  ; sid_binary_commit = "abc1234"
  ; sid_binary_commit_age_s = Some 10.
  ; sid_base_path = base_path
  ; sid_masc_root = base_path ^ "/.masc"
  ; sid_executable_in_worktree = Some false
  ; sid_state_ready = Some true
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
        ] )
    ]
