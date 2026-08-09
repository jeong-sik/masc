open Alcotest

let with_temp_root f =
  let root = Filename.temp_dir "masc-antigravity-home-" "" in
  Unix.chmod root 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () -> f root)
;;

let write_file ~mode path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents);
  Unix.chmod path mode
;;

let require_ok = function
  | Ok value -> value
  | Error error -> fail (Runtime_antigravity_home.error_to_string error)
;;

let permission path = (Unix.lstat path).Unix.st_perm land 0o7777

let test_prepares_private_home_without_copying_oauth () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "operator-secret-canary";
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-sangsu"
      ~oauth_source
    |> require_ok
  in
  let expected_home =
    Filename.concat runtime_root "official-clients"
    |> fun path -> Filename.concat path "antigravity"
    |> fun path -> Filename.concat path "keeper-sangsu"
  in
  check string "isolated HOME" expected_home layout.home_dir;
  check
    (list (pair string string))
    "child environment has no token"
    [ "HOME", expected_home ]
    (Runtime_antigravity_home.child_environment layout);
  let managed_directories =
    [ Filename.concat runtime_root "official-clients"
    ; Filename.concat (Filename.concat runtime_root "official-clients") "antigravity"
    ; layout.home_dir
    ; layout.workspace_dir
    ; Filename.concat layout.home_dir ".gemini"
    ; Filename.dirname layout.settings_path
    ; Filename.dirname layout.mcp_config_path
    ]
  in
  List.iter
    (fun path -> check int ("private directory " ^ path) 0o700 (permission path))
    managed_directories;
  check int "settings mode" 0o600 (permission layout.settings_path);
  check
    bool
    "settings contract"
    true
    (Yojson.Safe.equal
       (Runtime_antigravity_home.settings_json ())
       (Yojson.Safe.from_file layout.settings_path));
  check bool "oauth target is a symlink" true
    ((Unix.lstat layout.oauth_link_path).Unix.st_kind = Unix.S_LNK);
  check
    string
    "oauth link points to canonical source"
    (Unix.realpath oauth_source)
    (Unix.readlink layout.oauth_link_path);
  check
    string
    "source bytes remain operator-owned"
    "operator-secret-canary"
    (Fs_compat.load_file oauth_source);
  check bool "MCP capability is not persisted by HOME preparation" false
    (Sys.file_exists layout.mcp_config_path)
;;

let test_rejects_non_private_or_indirect_oauth_source () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o644 oauth_source "secret";
  (match
     Runtime_antigravity_home.prepare
       ~runtime_root
       ~owner_leaf:"keeper-sangsu"
       ~oauth_source
   with
   | Error (Runtime_antigravity_home.Invalid_oauth_source _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "0644 OAuth source was admitted");
  check bool "invalid source caused no managed mutation" false
    (Sys.file_exists (Filename.concat runtime_root "official-clients"));
  Unix.chmod oauth_source 0o600;
  let oauth_symlink = Filename.concat runtime_root "oauth-symlink" in
  Unix.symlink oauth_source oauth_symlink;
  match
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-sangsu"
      ~oauth_source:oauth_symlink
  with
  | Error (Runtime_antigravity_home.Invalid_oauth_source _) -> ()
  | Error error -> fail (Runtime_antigravity_home.error_to_string error)
  | Ok _ -> fail "symbolic-link OAuth source was admitted"
;;

let test_refuses_unexpected_existing_oauth_target () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "operator-secret";
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-sangsu"
      ~oauth_source
    |> require_ok
  in
  Unix.unlink layout.oauth_link_path;
  write_file ~mode:0o600 layout.oauth_link_path "do-not-overwrite";
  (match
     Runtime_antigravity_home.prepare
       ~runtime_root
       ~owner_leaf:"keeper-sangsu"
       ~oauth_source
   with
   | Error (Runtime_antigravity_home.Invalid_oauth_link _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "unexpected OAuth target was replaced");
  check
    string
    "unexpected target preserved"
    "do-not-overwrite"
    (Fs_compat.load_file layout.oauth_link_path)
;;

let test_rejects_owner_path_escape_before_mutation () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "secret";
  (match
     Runtime_antigravity_home.prepare
       ~runtime_root
       ~owner_leaf:"../outside"
       ~oauth_source
   with
   | Error (Runtime_antigravity_home.Invalid_owner_leaf "../outside") -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "owner path escape was admitted");
  check bool "managed root not created" false
    (Sys.file_exists (Filename.concat runtime_root "official-clients"))
;;

let () =
  run
    "runtime_antigravity_home"
    [ ( "layout"
      , [ test_case
            "private HOME and OAuth link"
            `Quick
            test_prepares_private_home_without_copying_oauth
        ; test_case
            "private direct OAuth source"
            `Quick
            test_rejects_non_private_or_indirect_oauth_source
        ; test_case
            "unexpected OAuth target"
            `Quick
            test_refuses_unexpected_existing_oauth_target
        ; test_case
            "owner path containment"
            `Quick
            test_rejects_owner_path_escape_before_mutation
        ] )
    ]
;;
