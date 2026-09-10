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
let env_value env key =
  let prefix = key ^ "=" in
  Array.to_list env
  |> List.filter_map (fun entry ->
    if String.starts_with ~prefix entry
    then Some (String.sub entry (String.length prefix) (String.length entry - String.length prefix))
    else None)
;;

(* [security create-keychain] appends the new keychain to the search list of
   the HOME it runs under. Run with the operator's HOME it grows
   ~/Library/Preferences/com.apple.security.plist on every preparation, and
   every later find-generic-password by any process walks the result. *)
let test_security_runs_under_the_managed_home () =
  let env = Runtime_antigravity_home.For_testing.security_environment ~home_dir:"/managed/home" in
  check (list string) "exactly one HOME" [ "/managed/home" ] (env_value env "HOME");
  check
    bool
    "inherited entries survive"
    true
    (Array.length env > 1 || Array.length (Unix.environment ()) <= 1)
;;

let operator_keychain_list () =
  let channel = Unix.open_process_in "/usr/bin/security list-keychains" in
  let rec drain acc =
    match input_line channel with
    | line -> drain (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = drain [] in
  ignore (Unix.close_process_in channel);
  lines
;;

let test_preparation_leaves_the_operator_keychain_list_alone () =
  if not security_available
  then check bool "no security tool" false security_available
  else
    with_temp_root
    @@ fun runtime_root ->
    let before = operator_keychain_list () in
    let layout = seeded_prepare runtime_root in
    let after = operator_keychain_list () in
    check
      (list string)
      "operator search list unchanged"
      before
      after;
    check
      bool
      "keychain still provisioned"
      true
      (match Runtime_antigravity_home.keychain_state layout with
       | Runtime_antigravity_home.Provisioned -> true
       | _ -> false)
;;

let read_command command =
  let channel = Unix.open_process_in command in
  let rec drain acc =
    match input_line channel with
    | line -> drain (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = drain [] in
  ignore (Unix.close_process_in channel);
  lines
;;

(* [create-keychain] leaves the keychain locking on sleep and 300s after the
   last read, and a keychain under this name cannot be unlocked again once it
   does. The settings call that clears both is the whole reason preparation
   spawns [security] twice. *)
let test_provisioned_keychain_never_locks_itself () =
  if not security_available
  then check bool "no security tool" false security_available
  else
    with_temp_root
    @@ fun runtime_root ->
    let layout = seeded_prepare runtime_root in
    let path = keychain_path (Runtime_antigravity_home.home_dir layout) in
    let info =
      read_command (Printf.sprintf "/usr/bin/security show-keychain-info %s 2>&1" (Filename.quote path))
      |> String.concat " "
    in
    check bool ("no-timeout in " ^ info) true (String_util.contains_substring info "no-timeout");
    check bool ("no lock-on-sleep in " ^ info) false (String_util.contains_substring info "lock-on-sleep")
;;

(* What a first preparation does with a keychain an earlier process left: the
   old file goes, a fresh one takes its place, and the fresh one carries the
   0600 mode and the cleared auto-lock rather than inheriting anything. *)
let test_replacing_a_carried_over_keychain_rebuilds_it () =
  if not security_available
  then check bool "no security tool" false security_available
  else
    with_temp_root
    @@ fun runtime_root ->
    let layout = seeded_prepare runtime_root in
    let home = Runtime_antigravity_home.home_dir layout in
    let path = keychain_path home in
    let before = (Unix.stat path).Unix.st_ino in
    let state = Runtime_antigravity_home.For_testing.replace_keychain ~home_dir:home path in
    check
      string
      "replaced"
      "provisioned"
      (Runtime_antigravity_home.keychain_state_to_string state);
    check bool "keychain exists" true (Sys.file_exists path);
    check bool "a different file" true ((Unix.stat path).Unix.st_ino <> before);
    check int "keychain mode" 0o600 (permission path);
    let info =
      read_command
        (Printf.sprintf "/usr/bin/security show-keychain-info %s 2>&1" (Filename.quote path))
      |> String.concat " "
    in
    check bool ("no-timeout in " ^ info) true (String_util.contains_substring info "no-timeout")
;;

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

let test_explicit_setup_import_and_login_home () =
  with_temp_root (fun runtime_root ->
    let account = match Runtime_antigravity_setup.prepare ~runtime_root ~account_id:"setup-account" with
      | Ok account -> account | Error error -> fail (Runtime_antigravity_setup.error_message error) in
    (match Runtime_antigravity_setup.credential_reference account with
     | Error Sign_in_required -> () | _ -> fail "login preparation must not fabricate credentials");
    let source_home = Filename.concat runtime_root "source-home" in
    let gemini = Filename.concat source_home ".gemini" in
    let cli = Filename.concat gemini "antigravity-cli" in
    List.iter (fun dir -> Unix.mkdir dir 0o700) [source_home;gemini;cli];
    let source = Filename.concat cli "antigravity-oauth-token" in
    write_file ~mode:0o600 source "fixture-operator-token";
    (match Runtime_antigravity_setup.import_signed_in ~source_home account with
     | Ok () -> () | Error error -> fail (Runtime_antigravity_setup.error_message error));
    let path = match Runtime_antigravity_setup.credential_reference account with
      | Ok (Runtime_schema.File path) -> path
      | _ -> fail "setup must produce an internal file reference without user typing" in
    check string "original auth unchanged" "fixture-operator-token" (Fs_compat.load_file source);
    check string "private copy" "fixture-operator-token" (Fs_compat.load_file path);
    check int "private import permissions" 0o600 (permission path);
    Unix.chmod source 0o644;
    (match Runtime_antigravity_setup.import_signed_in ~source_home account with
     | Error Unsafe_credential -> () | _ -> fail "unsafe canonical source must not fall through to another account"))
;;

let test_keychain_selection_and_private_account_switch () =
  with_temp_root (fun runtime_root ->
    let module S = Runtime_antigravity_setup in
    let account = match S.prepare ~runtime_root ~account_id:"switch-account" with
      | Ok account -> account | Error error -> fail (S.error_message error) in
    let source_home = Filename.concat runtime_root "source-switch" in
    Unix.mkdir source_home 0o700;
    List.iter (fun suffix -> Fs_compat.mkdir_p (Filename.concat source_home suffix))
      ["Library/Keychains"; ".gemini/antigravity-cli"];
    let source_keychain = Filename.concat source_home "Library/Keychains/login.keychain-db" in
    write_file ~mode:0o600 source_keychain "source keychain fixture unchanged";
    let source_file = Filename.concat source_home ".gemini/antigravity-cli/antigravity-oauth-token" in
    write_file ~mode:0o600 source_file "stale-file-account";
    let destination = Filename.concat (S.home_dir account) "Library/Keychains/login.keychain-db" in
    if not (Sys.file_exists destination) then (
      Fs_compat.mkdir_p (Filename.dirname destination);
      write_file ~mode:0o600 destination "private keychain fixture");
    let active_keychain_account = ref (Some "old-private-account") in
    let selected_account = ref (Apple_keychain.Found "selected-account-A") in
    let clears = ref 0 in
    let read_keychain ~path =
      check string "reads only explicitly selected source keychain" source_keychain path;
      !selected_account in
    let clear_keychain ~path =
      check string "only managed destination may be changed" destination path;
      incr clears; active_keychain_account := None; Ok () in
    let apply () = S.For_testing.import_with ~read_keychain ~clear_keychain ~source_home account in
    check bool "keychain A imported" true (apply () = Ok ());
    let reference () = match S.credential_reference account with
      | Ok (Runtime_schema.File path) -> Fs_compat.load_file path | _ -> fail "private account reference" in
    check string "keychain wins over stale fallback" "selected-account-A" (reference ());
    active_keychain_account := Some "selected-account-A";
    selected_account := Apple_keychain.Found "selected-account-B";
    check bool "second account imported" true (apply () = Ok ());
    check (option string) "old destination keychain cannot override B" None !active_keychain_account;
    check string "selected B copied" "selected-account-B" (reference ());
    check int "each explicit account switch clears only its private item" 2 !clears;
    selected_account := Apple_keychain.Unavailable;
    check bool "inaccessible keychain never falls back to stale file" true (apply () = Error S.Keychain_unavailable);
    check int "failed source selection leaves destination untouched" 2 !clears;
    check string "failed source selection preserves B" "selected-account-B" (reference ());
    selected_account := Apple_keychain.Found "selected-account-C";
    check bool "destination reset failure rejects switch" true
      (S.For_testing.import_with ~read_keychain ~clear_keychain:(fun ~path:_ -> Error ())
        ~source_home account = Error S.Keychain_unavailable);
    check string "failed destination reset preserves B" "selected-account-B" (reference ());
    selected_account := Apple_keychain.Missing;
    check bool "true missing item permits canonical fallback" true (apply () = Ok ());
    check string "explicit fallback captured" "stale-file-account" (reference ());
    let fresh_login = ref (Some "fresh-interactive-login") in
    check bool "capture reads same-home login before clearing private item" true
      (S.For_testing.import_with ~source_home:(S.home_dir account) account
         ~read_keychain:(fun ~path ->
           check string "capture reads own login keychain" destination path;
           match !fresh_login with Some token -> Apple_keychain.Found token | None -> Unavailable)
         ~clear_keychain:(fun ~path ->
           check string "capture clears only own login item" destination path;
           fresh_login := None; Ok ()) = Ok ());
    check string "captured login survives private reset" "fresh-interactive-login" (reference ());
    check string "source keychain never changed" "source keychain fixture unchanged" (Fs_compat.load_file source_keychain);
    check string "source file never changed" "stale-file-account" (Fs_compat.load_file source_file))
;;

let test_official_models_response_is_not_model_output () =
  let response turns = Printf.sprintf {|{"status":"SUCCESS","num_turns":%d,"usage":{"total_tokens":0},"command":{"name":"models","data":{"models":[{"id":"gemini-3.8-flash-high","label":"Gemini 3.8 Flash (High)"}]}}}|} turns in
  let models = match Runtime_antigravity_setup.parse_models (response 0) with
    | Ok models -> models | Error _ -> fail "measured official CLI envelope must parse" in
  check (list string) "actual model slug preserved" ["gemini-3.8-flash-high"]
    (List.map (fun (model : Runtime_antigravity_setup.model) -> model.id) models);
  check bool "model-generated catalog is not authoritative discovery" true
    (Result.is_error (Runtime_antigravity_setup.parse_models (response 1)));
  let json = Runtime_antigravity_setup.models_json models in
  check bool "discovery does not claim response/tool verification" false
    Yojson.Safe.Util.(json |> member "account_availability_verified" |> to_bool)
;;

let test_selected_model_zero_turn_context () =
  let model : Runtime_antigravity_setup.model = {id="gemini-3.8-flash-high";label="Gemini 3.8 Flash (High)"} in
  let payload label size input = Yojson.Safe.to_string (`Assoc [
    "version", `String "1.2.0";
    "model", `Assoc ["id",`String label;"display_name",`String label];
    "context_window", `Assoc ["context_window_size",`Int size;
      "total_input_tokens",`Int input;"total_output_tokens",`Int 0;"current_usage",`Null]]) in
  let parse = Runtime_antigravity_setup.parse_context ~model ~cli_version:"1.2.0" in
  (match parse (payload model.label 1048576 0) with
   | Ok (Observed_context 1048576) -> () | _ -> fail "official selected-model window must be observed");
  (match parse (payload model.label 0 0) with
   | Ok Unknown_context -> () | _ -> fail "initializing zero window must stay unknown");
  check bool "another model cannot supply selected context" true
    (Result.is_error (parse (payload "Gemini 3.8 Flash (Low)" 1048576 0)));
  check bool "model inference cannot masquerade as zero-turn metadata" true
    (Result.is_error (parse (payload model.label 1048576 1)))
;;

let () =
  run
    "runtime_antigravity_home"
    [ ( "setup", [test_case "explicit private account import" `Quick test_explicit_setup_import_and_login_home;
      test_case "keychain precedence and repeated account switch" `Quick test_keychain_selection_and_private_account_switch;
                       test_case "official model catalog envelope" `Quick test_official_models_response_is_not_model_output;
                       test_case "selected zero-turn context" `Quick test_selected_model_zero_turn_context] )
    ; ( "layout"
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
            "security runs under the managed HOME"
            `Quick
            test_security_runs_under_the_managed_home
        ; test_case
            "operator keychain search list untouched"
            `Quick
            test_preparation_leaves_the_operator_keychain_list_alone
        ; test_case
            "provisioned keychain never locks itself"
            `Quick
            test_provisioned_keychain_never_locks_itself
        ; test_case
            "carried-over keychain is rebuilt"
            `Quick
            test_replacing_a_carried_over_keychain_rebuilds_it
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
