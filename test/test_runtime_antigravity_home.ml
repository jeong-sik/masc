open Alcotest

let with_temp_root f =
  let root = Filename.temp_dir "masc-antigravity-home-" "" |> Unix.realpath in
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

let test_prepares_private_home_with_oauth_seed () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "operator-secret-canary";
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
    |> require_ok
  in
  let expected_home =
    Filename.concat runtime_root "official-clients"
    |> fun path -> Filename.concat path "antigravity"
    |> fun path -> Filename.concat path "keeper-alpha"
  in
  let home_dir = Runtime_antigravity_home.home_dir layout in
  let paths = Runtime_antigravity_home.For_testing.paths layout in
  check string "isolated HOME" expected_home home_dir;
  let managed_directories =
    [ Filename.concat runtime_root "official-clients"
    ; Filename.concat (Filename.concat runtime_root "official-clients") "antigravity"
    ; home_dir
    ; Filename.concat home_dir ".gemini"
    ; Filename.dirname paths.settings_path
    ; Filename.dirname paths.mcp_config_path
    ]
  in
  List.iter
    (fun path -> check int ("private directory " ^ path) 0o700 (permission path))
    managed_directories;
  check int "settings mode" 0o600 (permission paths.settings_path);
  check
    bool
    "settings contract"
    true
    (Yojson.Safe.equal
       (Runtime_antigravity_home.For_testing.settings_json ())
       (Yojson.Safe.from_file paths.settings_path));
  (match Runtime_antigravity_home.For_testing.settings_json () with
   | `Assoc fields ->
     check
       bool
       "no dead toolPermission key"
       false
       (List.mem_assoc "toolPermission" fields)
   | _ -> fail "settings must be a JSON object");
  check bool "oauth target is a regular file" true
    ((Unix.lstat paths.oauth_path).Unix.st_kind = Unix.S_REG);
  check int "managed oauth mode" 0o600 (permission paths.oauth_path);
  check
    string
    "managed oauth seed bytes"
    "operator-secret-canary"
    (Fs_compat.load_file paths.oauth_path);
  check
    string
    "source bytes remain operator-owned"
    "operator-secret-canary"
    (Fs_compat.load_file oauth_source);
  check bool "MCP capability is not persisted by HOME preparation" false
    (Sys.file_exists paths.mcp_config_path)
;;

let test_rejects_non_private_or_indirect_oauth_source () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o644 oauth_source "secret";
  (match
     Runtime_antigravity_home.prepare
       ~runtime_root
       ~owner_leaf:"keeper-alpha"
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
      ~owner_leaf:"keeper-alpha"
      ~oauth_source:oauth_symlink
  with
  | Error (Runtime_antigravity_home.Invalid_oauth_source _) -> ()
  | Error error -> fail (Runtime_antigravity_home.error_to_string error)
  | Ok _ -> fail "symbolic-link OAuth source was admitted"
;;

let test_preserves_runtime_managed_oauth_after_initial_seed () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "operator-secret";
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
    |> require_ok
  in
  let layout_paths = Runtime_antigravity_home.For_testing.paths layout in
  write_file ~mode:0o600 layout_paths.oauth_path "refreshed-runtime-secret";
  write_file ~mode:0o600 oauth_source "stale-operator-secret";
  let refreshed =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
    |> require_ok
  in
  let refreshed_paths = Runtime_antigravity_home.For_testing.paths refreshed in
  check
    string
    "runtime refresh survives later preparation"
    "refreshed-runtime-secret"
    (Fs_compat.load_file refreshed_paths.oauth_path);
  check
    string
    "bootstrap source remains external"
    "stale-operator-secret"
    (Fs_compat.load_file oauth_source);
  check string
    "stable isolated path"
    layout_paths.oauth_path
    refreshed_paths.oauth_path
;;

let test_rejects_unsafe_existing_runtime_oauth () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "operator-secret";
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
    |> require_ok
  in
  let oauth_path = (Runtime_antigravity_home.For_testing.paths layout).oauth_path in
  Unix.chmod oauth_path 0o644;
  match
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
  with
  | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
  | Error error -> fail (Runtime_antigravity_home.error_to_string error)
  | Ok _ -> fail "unsafe existing runtime OAuth file was silently replaced"
;;

let test_mcp_capability_is_turn_scoped () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o600 oauth_source "operator-secret";
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
    |> require_ok
  in
  let paths = Runtime_antigravity_home.For_testing.paths layout in
  let config =
    `Assoc
      [ ( "mcpServers"
        , `Assoc
            [ ( "masc"
              , `Assoc [ "url", `String "http://127.0.0.1:1234/mcp" ] )
            ] )
      ]
  in
  Runtime_antigravity_home.publish_mcp_config layout config |> require_ok;
  check int "MCP config mode" 0o600 (permission paths.mcp_config_path);
  check bool "published exact MCP config" true
    (Yojson.Safe.equal config (Yojson.Safe.from_file paths.mcp_config_path));
  Runtime_antigravity_home.clear_mcp_config layout |> require_ok;
  check bool "turn capability removed" false (Sys.file_exists paths.mcp_config_path)
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

let security_available =
  try
    Unix.access "/usr/bin/security" [ Unix.X_OK ];
    true
  with
  | Unix.Unix_error _ -> false
;;

let keychain_path home_dir =
  List.fold_left Filename.concat home_dir [ "Library"; "Keychains"; "login.keychain-db" ]
;;

let seeded_prepare runtime_root =
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  if not (Sys.file_exists oauth_source)
  then write_file ~mode:0o600 oauth_source "operator-secret-canary";
  Runtime_antigravity_home.prepare
    ~runtime_root
    ~owner_leaf:"keeper-alpha"
    ~oauth_source
  |> require_ok
;;

(* macOS resolves a HOME's login keychain only from this path. Without the
   file the CLI's token save finds no default keychain and macOS raises an
   operator dialog asking to create one (masc#28922). *)
let test_provisions_login_keychain_at_the_conventional_path () =
  with_temp_root
  @@ fun runtime_root ->
  let layout = seeded_prepare runtime_root in
  let path = keychain_path (Runtime_antigravity_home.home_dir layout) in
  match Runtime_antigravity_home.keychain_state layout with
  | Runtime_antigravity_home.Provisioned ->
    check bool "security available" true security_available;
    check bool "keychain exists" true (Sys.file_exists path);
    check int "keychain mode" 0o600 (permission path)
  | Runtime_antigravity_home.Unsupported ->
    check bool "no security tool" false security_available;
    check bool "no keychain written" false (Sys.file_exists path)
  | state ->
    fail
      ("unexpected keychain state: "
       ^ Runtime_antigravity_home.keychain_state_to_string state)
;;

let test_second_preparation_keeps_the_existing_keychain () =
  with_temp_root
  @@ fun runtime_root ->
  let first = seeded_prepare runtime_root in
  let path = keychain_path (Runtime_antigravity_home.home_dir first) in
  if not security_available
  then check bool "no keychain written" false (Sys.file_exists path)
  else (
    let before = (Unix.lstat path).Unix.st_ino in
    let second = seeded_prepare runtime_root in
    check
      string
      "second preparation reports present"
      "present"
      (Runtime_antigravity_home.keychain_state second
       |> Runtime_antigravity_home.keychain_state_to_string);
    check bool "same file" true (before = (Unix.lstat path).Unix.st_ino))
;;

(* The CLI creates [Library] itself at 0755 for its own caches, so a home that
   has already run a turn carries a directory the 0700 contract would reject.
   Preparation must survive it — every antigravity turn calls this. *)
let test_tolerates_a_cli_created_library_directory () =
  with_temp_root
  @@ fun runtime_root ->
  let home_dir =
    List.fold_left
      Filename.concat
      runtime_root
      [ "official-clients"; "antigravity"; "keeper-alpha" ]
  in
  List.iter
    (fun path -> if not (Sys.file_exists path) then Unix.mkdir path 0o700)
    [ Filename.concat runtime_root "official-clients"
    ; Filename.concat (Filename.concat runtime_root "official-clients") "antigravity"
    ; home_dir
    ];
  Unix.mkdir (Filename.concat home_dir "Library") 0o755;
  let layout = seeded_prepare runtime_root in
  match Runtime_antigravity_home.keychain_state layout with
  | Runtime_antigravity_home.Failed detail -> fail ("keychain provisioning failed: " ^ detail)
  | Runtime_antigravity_home.Present
  | Runtime_antigravity_home.Provisioned
  | Runtime_antigravity_home.Unsupported -> ()
;;

let () =
  run
    "runtime_antigravity_home"
    [ ( "layout"
      , [ test_case
            "private HOME and OAuth seed"
            `Quick
            test_prepares_private_home_with_oauth_seed
        ; test_case
            "private direct OAuth source"
            `Quick
            test_rejects_non_private_or_indirect_oauth_source
        ; test_case
            "runtime OAuth refresh survives preparation"
            `Quick
            test_preserves_runtime_managed_oauth_after_initial_seed
        ; test_case
            "unsafe existing runtime OAuth"
            `Quick
            test_rejects_unsafe_existing_runtime_oauth
        ; test_case
            "turn-scoped MCP capability"
            `Quick
            test_mcp_capability_is_turn_scoped
        ; test_case
            "owner path containment"
            `Quick
            test_rejects_owner_path_escape_before_mutation
        ; test_case
            "login keychain at the conventional path"
            `Quick
            test_provisions_login_keychain_at_the_conventional_path
        ; test_case
            "second preparation keeps the keychain"
            `Quick
            test_second_preparation_keeps_the_existing_keychain
        ; test_case
            "CLI-created Library directory"
            `Quick
            test_tolerates_a_cli_created_library_directory
        ] )
    ]
;;
