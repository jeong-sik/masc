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
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-secret-canary");
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
  check string "account generation remains under its owner" expected_home (Filename.dirname home_dir);
  check bool "generation is an opaque UUID" true
    (Result.is_ok (Random_id.parse_uuid_v7 (Filename.basename home_dir)));
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
    (Masc_test_deps.antigravity_oauth_fixture "operator-secret-canary")
    (Fs_compat.load_file paths.oauth_path);
  check
    string
    "source bytes remain operator-owned"
    (Masc_test_deps.antigravity_oauth_fixture "operator-secret-canary")
    (Fs_compat.load_file oauth_source);
  check bool "MCP capability is not persisted by HOME preparation" false
    (Sys.file_exists paths.mcp_config_path)
;;

let test_keeper_account_switch_preserves_each_refreshed_home () =
  with_temp_root @@ fun runtime_root ->
  let source_a = Filename.concat runtime_root "account-a" in
  let source_b = Filename.concat runtime_root "account-b" in
  write_file ~mode:0o600 source_a (Masc_test_deps.antigravity_oauth_fixture "synthetic-a");
  write_file ~mode:0o600 source_b (Masc_test_deps.antigravity_oauth_fixture "synthetic-b");
  let prepare oauth_source =
    let owner_leaf = Runtime_antigravity_home.keeper_owner_leaf
        ~keeper_name:"keeper-alpha" ~oauth_source in
    let home = Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf ~oauth_source
      |> require_ok in
    home in
  let first = prepare source_a in
  write_file ~mode:0o600 (Runtime_antigravity_home.oauth_path first) (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "synthetic-a");
  let second = prepare source_b in
  check bool "source selection changes managed HOME" false
    (String.equal (Runtime_antigravity_home.home_dir first)
       (Runtime_antigravity_home.home_dir second));
  check string "new source seeds its own account" (Masc_test_deps.antigravity_oauth_fixture "synthetic-b")
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path second));
  let surface home = Masc.Keeper_official_client_session_store.tool_surface_sha256
      ~account_home:(Runtime_antigravity_home.home_dir home)
      ~native_posture:Runtime_native_tools.Native_read [] in
  check bool "old vendor session cannot retain its account surface" false
    (String.equal (surface first) (surface second));
  let returned = prepare source_a in
  check string "return selects previous account HOME"
    (Runtime_antigravity_home.home_dir first) (Runtime_antigravity_home.home_dir returned);
  check string "refresh survives unchanged source" (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "synthetic-a")
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path returned));
  check string "refresh is not session identity" (surface first) (surface returned);
  write_file ~mode:0o600 source_a
    (Masc_test_deps.antigravity_oauth_fixture ~revision:"external-source-refresh" "synthetic-a");
  let source_refreshed = prepare source_a in
  check string "ordinary source token refresh retains the account generation"
    (Runtime_antigravity_home.home_dir first) (Runtime_antigravity_home.home_dir source_refreshed);
  check string "source refresh keeps the native-refreshed credential"
    (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "synthetic-a")
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path source_refreshed));
  check string "ordinary source refresh does not change session identity"
    (surface first) (surface source_refreshed);
  write_file ~mode:0o600 source_a (Masc_test_deps.antigravity_oauth_fixture "changed-seed-a");
  let relogged = prepare source_a in
  check bool "same-path external login changes HOME" true
    (Runtime_antigravity_home.home_dir first <> Runtime_antigravity_home.home_dir relogged);
  check bool "same-path external login changes session identity" true
    (surface first <> surface relogged);
  check string "new login bytes are selected" (Masc_test_deps.antigravity_oauth_fixture "changed-seed-a")
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path relogged));
  check string "in-flight old generation remains untouched" (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "synthetic-a")
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path first))
;;

let test_account_identity_preparation_does_not_reset_active_policy () =
  with_temp_root @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "source" in
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "synthetic-source");
  let home, _ = Runtime_antigravity_home.prepare_native ~runtime_root
      ~owner_leaf:"active-policy" ~oauth_source ~posture:Runtime_native_tools.Native_read
      ~workspace:Runtime_antigravity_home.Private_workspace ~additional_workspaces:[] |> require_ok in
  let settings = (Runtime_antigravity_home.For_testing.paths home).settings_path in
  let policy_before = Fs_compat.load_file settings in
  let refreshed = Masc_test_deps.antigravity_oauth_fixture
      ~revision:"native-refresh" "synthetic-source" in
  write_file ~mode:0o600 (Runtime_antigravity_home.oauth_path home) refreshed;
  let planned = Runtime_antigravity_home.prepare_account ~runtime_root
      ~owner_leaf:"active-policy" ~oauth_source |> require_ok in
  check string "planning retains the account generation" (Runtime_antigravity_home.home_dir home)
    (Runtime_antigravity_home.home_dir planned);
  ignore (Runtime_antigravity_home.prepare_native_workspace planned
    ~workspace:Runtime_antigravity_home.Private_workspace |> require_ok);
  check string "identity and workspace planning cannot reset the active permission policy"
    policy_before (Fs_compat.load_file settings);
  check string "planning cannot replace native refresh" refreshed
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path planned))
;;

let test_every_managed_hierarchy_link_reconfirms_parent_sync () =
  with_temp_root @@ fun runtime_root ->
  let synced = ref [] in
  let sync_parent parent = synced := parent :: !synced in
  let _ = List.fold_left (fun parent leaf ->
    synced := [];
    let path = Runtime_antigravity_home.For_testing.ensure_private_child_with_sync
      ~sync_parent parent leaf |> require_ok in
    check (list string) "created child confirms its parent" [parent] !synced;
    synced := [];
    let existing = Runtime_antigravity_home.For_testing.ensure_private_child_with_sync
      ~sync_parent parent leaf |> require_ok in
    check string "existing child is stable" path existing;
    check (list string) "visible child reconfirms its parent" [parent] !synced;
    path) runtime_root ["official-clients"; "antigravity"; "owner"; "generation"; ".gemini"; "antigravity-cli"] in
  ()
;;

let test_failed_parent_sync_retries_visible_child () =
  with_temp_root @@ fun runtime_root ->
  let attempts = ref [] in
  let sync_parent parent =
    attempts := parent :: !attempts;
    if List.length !attempts = 1 then raise (Unix.Unix_error (Unix.EIO, "fsync", parent)) in
  let prepare () = Runtime_antigravity_home.For_testing.ensure_private_child_with_sync
    ~sync_parent runtime_root "interrupted-publication" in
  (match prepare () with
   | Error (Runtime_antigravity_home.Unsafe_directory _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "directory admitted after failed parent sync");
  check bool "failed publication can leave its directory visible" true
    (Sys.is_directory (Filename.concat runtime_root "interrupted-publication"));
  ignore (prepare () |> require_ok);
  check (list string) "EEXIST retry synchronizes the parent again"
    [runtime_root; runtime_root] (List.rev !attempts)
;;

let test_generation_pointer_failure_retry ~after_rename () =
  List.iter (fun has_previous ->
    with_temp_root @@ fun runtime_root ->
    let oauth_source = Filename.concat runtime_root "source" in
    let owner_leaf = "pointer-retry" in
    let prepare () = Runtime_antigravity_home.prepare_account ~runtime_root ~owner_leaf ~oauth_source in
    let refreshed_a = Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "account-a" in
    let previous = if has_previous then (
      write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "account-a");
      let home = prepare () |> require_ok in
      write_file ~mode:0o600 (Runtime_antigravity_home.oauth_path home) refreshed_a;
      Some home)
      else None in
    let store = Filename.concat runtime_root
        (Filename.concat "official-clients" (Filename.concat "antigravity" owner_leaf)) in
    let pointer = Filename.concat store "current.json" in
    let entries () = Sys.readdir store |> Array.to_list |> List.sort String.compare in
    let previous_entries, previous_pointer = match previous with
      | None -> [], None
      | Some _ -> entries (), Some (Fs_compat.load_file pointer) in
    write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "account-b");
    let sync path =
      let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd) in
    let failures = ref [] in
    let fail_sync path =
      failures := path :: !failures;
      raise (Unix.Unix_error (Unix.EIO, "fsync", path)) in
    let expect_refusal = function
      | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
      | Error error -> fail (Runtime_antigravity_home.error_to_string error)
      | Ok _ -> fail "failed publication admitted an account" in
    Runtime_antigravity_home.For_testing.prepare_account_with_store_sync
      ~runtime_root ~owner_leaf ~oauth_source ~sync_store:sync
      ~sync_pointer_file:(if after_rename then sync else fail_sync)
      ~sync_pointer_parent:(if after_rename then fail_sync else sync) ()
    |> expect_refusal;
    check int "failure occurred inside the pointer writer" 1 (List.length !failures);
    if after_rename then (
      check (list string) "failed sync targets pointer parent" [store] !failures;
      let record = Fs_compat.load_file pointer in
      let revision = Yojson.Safe.from_string record |> Yojson.Safe.Util.member "revision"
          |> Yojson.Safe.Util.to_string in
      let referenced_home = Filename.concat store revision in
      check bool "published pointer retains its referenced HOME" true (Sys.is_directory referenced_home);
      check int "visible pointer remains private" 0o600 (permission pointer);
      check (list string) "only the new generation and pointer are published"
        (List.sort String.compare (revision :: "current.json" ::
          List.filter (fun entry -> entry <> "current.json") previous_entries)) (entries ());
      let token = Filename.concat referenced_home ".gemini/antigravity-cli/antigravity-oauth-token" in
      let refreshed_b = Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "account-b" in
      write_file ~mode:0o600 token refreshed_b;
      failures := [];
      Runtime_antigravity_home.For_testing.prepare_account_with_store_sync
        ~runtime_root ~owner_leaf ~oauth_source ~sync_store:fail_sync () |> expect_refusal;
      check (list string) "readmission reconfirms exactly the pointer directory" [store] !failures;
      check string "retry refusal preserves the visible pointer" record (Fs_compat.load_file pointer);
      check string "retry refusal preserves native refresh" refreshed_b (Fs_compat.load_file token);
      let recovered = prepare () |> require_ok in
      check string "successful retry uses the referenced generation" referenced_home
        (Runtime_antigravity_home.home_dir recovered);
      check string "successful retry preserves native refresh" refreshed_b
        (Fs_compat.load_file (Runtime_antigravity_home.oauth_path recovered)))
    else (
      check (list string) "pre-rename refusal removes only the unpublished generation"
        previous_entries (entries ());
      check (option string) "pre-rename refusal preserves the previous pointer" previous_pointer
        (if Sys.file_exists pointer then Some (Fs_compat.load_file pointer) else None);
      let recovered = prepare () |> require_ok in
      check string "retry seeds the newly selected account"
        (Masc_test_deps.antigravity_oauth_fixture "account-b")
        (Fs_compat.load_file (Runtime_antigravity_home.oauth_path recovered));
      let readmitted = prepare () |> require_ok in
      check string "retry publishes a reusable generation"
        (Runtime_antigravity_home.home_dir recovered) (Runtime_antigravity_home.home_dir readmitted));
    match previous with
    | None -> ()
    | Some home -> check string "in-flight previous generation retains native refresh"
        refreshed_a (Fs_compat.load_file (Runtime_antigravity_home.oauth_path home)))
    [false; true]
;;

let test_pointerless_store_reseeds_only_a_fresh_seed () =
  let seed_a = Masc_test_deps.antigravity_oauth_fixture "account-a" in
  let seed_b = Masc_test_deps.antigravity_oauth_fixture "account-b" in
  let seed_captured_orphan revision_dir ~seed =
    (* The exact layout a process death between [Unix.mkdir] and the pointer
       rename leaves behind. *)
    let rec mkdir_p path =
      if not (Sys.file_exists path) then begin
        mkdir_p (Filename.dirname path);
        Unix.mkdir path 0o700
      end in
    let gemini_dir = Filename.concat revision_dir ".gemini" in
    let cli_dir = Filename.concat gemini_dir "antigravity-cli" in
    mkdir_p cli_dir;
    Unix.mkdir (Filename.concat gemini_dir "config") 0o700;
    write_file ~mode:0o600 (Filename.concat cli_dir "antigravity-oauth-token") seed in
  (* A crash-window orphan plus the writer's staged temp reseeds. *)
  with_temp_root @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "source" in
  write_file ~mode:0o600 oauth_source seed_a;
  let owner_leaf = "orphan-reseed" in
  let store = Filename.concat runtime_root
      (Filename.concat "official-clients" (Filename.concat "antigravity" owner_leaf)) in
  let prepare () = Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf ~oauth_source in
  let entries () = Sys.readdir store |> Array.to_list |> List.sort String.compare in
  seed_captured_orphan (Filename.concat store "00000000-0000-7000-8000-000000000000")
    ~seed:seed_a;
  write_file ~mode:0o600 (Filename.concat store ".atomic_dead_publish.tmp") "{partial";
  let recovered = prepare () |> require_ok in
  check bool "the crash-window orphan is cleared" false
    (Sys.file_exists (Filename.concat store "00000000-0000-7000-8000-000000000000"));
  check bool "the writer's staged temp is cleared" false
    (Sys.file_exists (Filename.concat store ".atomic_dead_publish.tmp"));
  check (list string) "only the fresh generation and pointer remain"
    [Filename.basename (Runtime_antigravity_home.home_dir recovered); "current.json"]
    (entries ());
  check string "the fresh generation reseeds the selected account" seed_a
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path recovered));
  (* CLI state beyond a fresh seed refuses and is preserved untouched. *)
  let second = Runtime_antigravity_home.home_dir recovered in
  Unix.mkdir (Filename.concat (Filename.concat second ".gemini")
      (Filename.concat "antigravity-cli" "cache")) 0o700;
  Unix.unlink (Filename.concat store "current.json");
  let snapshot = entries () in
  (match prepare () with
   | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "an unreferenced generation with CLI state was admitted");
  check (list string) "refusal preserves every unreferenced entry" snapshot (entries ());
  check bool "refusal preserves the CLI state" true
    (Sys.is_directory (Filename.concat (Filename.concat second ".gemini")
         (Filename.concat "antigravity-cli" "cache")));
  (* A vendor-refreshed credential beyond the seed also refuses. *)
  let third = Filename.concat store "00000000-0000-7000-8000-000000000001" in
  seed_captured_orphan third ~seed:seed_b;
  Unix.unlink (Filename.concat third ".gemini/antigravity-cli/antigravity-oauth-token");
  write_file ~mode:0o600 (Filename.concat third ".gemini/antigravity-cli/antigravity-oauth-token")
    (Masc_test_deps.antigravity_oauth_fixture ~revision:"vendor-refresh" "account-a");
  let refreshed = Fs_compat.load_file
      (Filename.concat third ".gemini/antigravity-cli/antigravity-oauth-token") in
  (match prepare () with
   | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "a vendor-refreshed unreferenced credential was discarded");
  check bool "refusal preserves the refreshed credential's generation" true
    (Sys.file_exists third);
  check string "refusal preserves the refreshed credential bytes" refreshed
    (Fs_compat.load_file (Filename.concat third ".gemini/antigravity-cli/antigravity-oauth-token"))
;;

let test_generation_pointer_is_private_under_standard_umask () =
  with_temp_root @@ fun runtime_root ->
  let previous_umask = Unix.umask 0o022 in
  Fun.protect ~finally:(fun () -> ignore (Unix.umask previous_umask)) @@ fun () ->
  let oauth_source = Filename.concat runtime_root "source" in
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "account-a");
  let prepare () = Runtime_antigravity_home.prepare_account
      ~runtime_root ~owner_leaf:"pointer-mode" ~oauth_source |> require_ok in
  let first = prepare () in
  let pointer = Filename.concat (Filename.dirname (Runtime_antigravity_home.home_dir first)) "current.json" in
  check int "atomic pointer is 0600 under 0022 umask" 0o600 (permission pointer);
  let refreshed = Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "account-a" in
  write_file ~mode:0o600 (Runtime_antigravity_home.oauth_path first) refreshed;
  let reused = prepare () in
  check string "private pointer is accepted on the next preparation"
    (Runtime_antigravity_home.home_dir first) (Runtime_antigravity_home.home_dir reused);
  check string "next preparation preserves refreshed credentials" refreshed
    (Fs_compat.load_file (Runtime_antigravity_home.oauth_path reused))
;;

let test_corrupt_generation_never_reseeds_managed_state () =
  List.iter (fun corruption ->
    with_temp_root @@ fun runtime_root ->
    let oauth_source = Filename.concat runtime_root "source" in
    let source = Masc_test_deps.antigravity_oauth_fixture "synthetic-source" in
    write_file ~mode:0o600 oauth_source source;
    let prepare () = Runtime_antigravity_home.prepare ~runtime_root
        ~owner_leaf:"corruption-fixture" ~oauth_source in
    let home = prepare () |> require_ok in
    let token = Runtime_antigravity_home.oauth_path home in
    let store = Filename.dirname (Runtime_antigravity_home.home_dir home) in
    let pointer = Filename.concat store "current.json" in
    let original_pointer = Fs_compat.load_file pointer in
    let refreshed = Masc_test_deps.antigravity_oauth_fixture
        ~revision:"managed-refresh" "synthetic-source" in
    write_file ~mode:0o600 token refreshed;
    (match corruption with
     | `Record -> write_file ~mode:0o600 pointer "{broken"
     | `Record_permissions -> Unix.chmod pointer 0o644
     | `Missing_record -> Unix.unlink pointer
     | `Missing_token -> Unix.unlink token
     | `Managed_principal -> write_file ~mode:0o600 token
         (Masc_test_deps.antigravity_oauth_fixture "different-native-account")
     | `Managed_malformed -> write_file ~mode:0o600 token "{broken");
    let token_before = if Sys.file_exists token then Some (Fs_compat.load_file token) else None in
    let entries_before = Sys.readdir store |> Array.to_list |> List.sort String.compare in
    (match prepare () with
     | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
     | Error error -> fail (Runtime_antigravity_home.error_to_string error)
     | Ok _ -> fail "corrupt authoritative generation was admitted");
    check (list string) "refusal creates no replacement generation" entries_before
      (Sys.readdir store |> Array.to_list |> List.sort String.compare);
    check (option string) "refusal never overwrites or reseeds native credential" token_before
      (if Sys.file_exists token then Some (Fs_compat.load_file token) else None);
    check string "external source remains unchanged" source (Fs_compat.load_file oauth_source);
    match corruption with
    | `Missing_record -> check bool "missing pointer was not silently recreated" false (Sys.file_exists pointer)
    | `Managed_principal | `Managed_malformed | `Missing_token ->
      check string "authoritative pointer remains unchanged" original_pointer (Fs_compat.load_file pointer)
    | `Record | `Record_permissions -> ())
    [`Record; `Record_permissions; `Missing_record; `Missing_token;
     `Managed_principal; `Managed_malformed]
;;

let test_interrupted_generation_creation_leaves_no_orphan () =
  with_temp_root @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "source" in
  let owner_leaf = "interrupted-creation" in
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "account-a");
  let store = Filename.concat runtime_root
      (Filename.concat "official-clients" (Filename.concat "antigravity" owner_leaf)) in
  let attempts = ref [] in
  (match Runtime_antigravity_home.For_testing.prepare_account_with_store_sync
      ~runtime_root ~owner_leaf ~oauth_source
      ~sync_store:(fun dir -> attempts := dir :: !attempts;
        raise (Unix.Unix_error (Unix.EIO, "fsync", dir))) () with
   | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "interrupted generation creation was admitted");
  check bool "interrupted publication attempted a directory sync" true (!attempts <> []);
  check (list string) "failed creation leaves no unpublished generation" []
    (Sys.readdir store |> Array.to_list |> List.sort String.compare);
  check bool "failed creation publishes no pointer" false
    (Sys.file_exists (Filename.concat store "current.json"));
  let recovered =
    Runtime_antigravity_home.prepare_account ~runtime_root ~owner_leaf ~oauth_source |> require_ok in
  check int "retry publishes exactly one generation plus its pointer" 2
    (Sys.readdir store |> Array.to_list |> List.length);
  let readmitted =
    Runtime_antigravity_home.prepare_account ~runtime_root ~owner_leaf ~oauth_source |> require_ok in
  check string "retry completes the account generation"
    (Runtime_antigravity_home.home_dir recovered) (Runtime_antigravity_home.home_dir readmitted)
;;

let test_managed_keychain_principal_must_match_selected_generation () =
  with_temp_root @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "source" in
  let owner_leaf = "keychain-principal" in
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "account-a");
  let sync dir =
    let fd = Unix.openfile dir [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd) in
  let observed = ref [] in
  let prepare_with keychain =
    Runtime_antigravity_home.For_testing.prepare_account_with_store_sync
      ~sync_store:sync
      ~read_keychain:(fun ~path -> observed := path :: !observed; keychain)
      ~runtime_root ~owner_leaf ~oauth_source () in
  let first = prepare_with Apple_keychain.Missing |> require_ok in
  let home_dir = Runtime_antigravity_home.home_dir first in
  let store = Filename.dirname home_dir in
  let pointer = Filename.concat store "current.json" in
  let entries_before = Sys.readdir store |> Array.to_list |> List.sort String.compare in
  let pointer_before = Fs_compat.load_file pointer in
  let managed_keychain = Filename.concat home_dir
      (Filename.concat "Library" (Filename.concat "Keychains" "login.keychain-db")) in
  check (list string) "fresh generation creation consults no keychain" [] !observed;
  observed := [];
  (match prepare_with (Apple_keychain.Found (Masc_test_deps.antigravity_oauth_fixture "account-b")) with
   | Error (Runtime_antigravity_home.Invalid_managed_oauth _) -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error)
   | Ok _ -> fail "keychain principal from another account was admitted");
  check (list string) "reuse consults the managed login keychain" [managed_keychain] !observed;
  check (list string) "divergent keychain creates no replacement generation" entries_before
    (Sys.readdir store |> Array.to_list |> List.sort String.compare);
  check string "divergent keychain keeps the authoritative pointer" pointer_before (Fs_compat.load_file pointer);
  let refreshed = prepare_with
      (Apple_keychain.Found (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "account-a"))
    |> require_ok in
  check string "keychain refresh for the same principal preserves the generation" home_dir
    (Runtime_antigravity_home.home_dir refreshed);
  List.iter (fun observation ->
    let readmitted = prepare_with observation |> require_ok in
    check string "unreadable keychain leaves the file authoritative" home_dir
      (Runtime_antigravity_home.home_dir readmitted))
    [Apple_keychain.Missing; Apple_keychain.Unsupported; Apple_keychain.Unavailable]
;;

let test_native_permissions_match_posture_and_workspace () =
  with_temp_root @@ fun runtime_root ->
  let source = Filename.concat runtime_root "source" in
  write_file ~mode:0o600 source (Masc_test_deps.antigravity_oauth_fixture "synthetic");
  let home = Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf:"native-policy"
      ~oauth_source:source |> require_ok in
  let workspace = Filename.concat runtime_root "workspace" in
  Unix.mkdir workspace 0o700;
  let check_policy posture expected_allow expected_deny =
    let cwd = Runtime_antigravity_home.prepare_native_tools home ~additional_workspaces:[] ~posture
        ~workspace:(Runtime_antigravity_home.Shared_workspace workspace) |> require_ok in
    check string "native cwd is the actual granted directory" workspace cwd;
    let paths = Runtime_antigravity_home.For_testing.paths home in
    let open Yojson.Safe.Util in
    let settings = Yojson.Safe.from_file paths.settings_path |> member "permissions" in
    let rules field = settings |> member field |> to_list |> List.map to_string in
    check (list string) "exact positive grants" expected_allow (rules "allow");
    check (list string) "effect/network boundaries" expected_deny (rules "deny");
    check bool "no workspace-wide root read" false
      (List.mem ("read_file(" ^ runtime_root ^ ")") (rules "allow"));
    check bool "no all-files read" false (List.mem "read_file(*)" (rules "allow"));
    check bool "no command grant can authorize sandbox escape" false
      (List.mem "command(*)" (rules "allow"));
    check bool "no unsupported unsandboxed rule" false
      (List.mem "unsandboxed(*)" (rules "deny")) in
  let network_denies = ["read_url(*)"; "execute_url(*)"] in
  check_policy Runtime_native_tools.Native_read
    ["mcp(masc/*)"; "read_file(" ^ workspace ^ ")"]
    (["write_file(*)"; "command(*)"] @ network_denies);
  check_policy Runtime_native_tools.Native_full
    ["mcp(masc/*)"; "read_file(" ^ workspace ^ ")";
     "write_file(" ^ workspace ^ ")"] network_denies;
  let extra = Filename.concat runtime_root "operator-extra" in
  Unix.mkdir extra 0o700;
  ignore (Runtime_antigravity_home.prepare_native_tools home
    ~additional_workspaces:[extra] ~posture:Runtime_native_tools.Native_full
    ~workspace:(Runtime_antigravity_home.Shared_workspace workspace) |> require_ok);
  let paths = Runtime_antigravity_home.For_testing.paths home in
  let open Yojson.Safe.Util in
  let extra_grants = Yojson.Safe.from_file paths.settings_path
    |> member "permissions" |> member "allow" |> to_list |> List.map to_string in
  check bool "explicit operator extra root remains readable" true
    (List.mem ("read_file(" ^ extra ^ ")") extra_grants);
  check bool "explicit operator extra root remains writable" true
    (List.mem ("write_file(" ^ extra ^ ")") extra_grants);
  let private_cwd = Runtime_antigravity_home.prepare_native_tools home ~additional_workspaces:[]
      ~posture:Runtime_native_tools.Native_read
      ~workspace:Runtime_antigravity_home.Private_workspace |> require_ok in
  check int "private endpoint host cwd" 0o700 (permission private_cwd);
  check (list string) "endpoint workspace starts empty" [] (Array.to_list (Sys.readdir private_cwd));
  let indirect = Filename.concat runtime_root "workspace-link" in
  Unix.symlink workspace indirect;
  check bool "workspace symlink refused" true
    (Result.is_error (Runtime_antigravity_home.prepare_native_tools home ~additional_workspaces:[]
      ~posture:Runtime_native_tools.Native_full
      ~workspace:(Runtime_antigravity_home.Shared_workspace indirect)));
  let wildcard = Filename.concat runtime_root "wild*workspace" in
  Unix.mkdir wildcard 0o700;
  check bool "filesystem name cannot inject permission glob" true
    (Result.is_error (Runtime_antigravity_home.prepare_native_tools home ~additional_workspaces:[]
      ~posture:Runtime_native_tools.Native_full
      ~workspace:(Runtime_antigravity_home.Shared_workspace wildcard)))
;;

let test_unknown_account_identity_causes_no_managed_mutation () =
  let credential claims =
    let payload = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
      (Yojson.Safe.to_string claims) in
    let source = Masc_test_deps.antigravity_oauth_fixture "fixture" |> Yojson.Safe.from_string in
    match source with
    | `Assoc fields -> Yojson.Safe.to_string (`Assoc
        (("id_token", `String ("synthetic-header." ^ payload ^ ".synthetic-signature")) ::
         List.remove_assoc "id_token" fields))
    | _ -> fail "fixture source must be an object" in
  List.iter (fun source -> with_temp_root (fun runtime_root ->
    let oauth_source = Filename.concat runtime_root "invalid-source" in
    write_file ~mode:0o600 oauth_source source;
    (match Runtime_antigravity_home.prepare ~runtime_root ~owner_leaf:"unknown-account" ~oauth_source with
     | Error (Runtime_antigravity_home.Invalid_oauth_source _) -> ()
     | Error error -> fail (Runtime_antigravity_home.error_to_string error)
     | Ok _ -> fail "unknown account identity was admitted");
    check bool "unknown identity creates no managed account tree" false
      (Sys.file_exists (Filename.concat runtime_root "official-clients"))))
    [""; "opaque-token"; "{}";
     credential (`Assoc ["iss", `String "https://unknown.invalid"; "sub", `String "fixture"]);
     credential (`Assoc ["iss", `String "https://accounts.google.com"]);
     credential (`Assoc ["iss", `String "https://accounts.google.com"; "sub", `Null]);
     credential (`Assoc ["iss", `String "https://accounts.google.com"; "sub", `String (String.make 256 'x')]);
     credential (`Assoc ["iss", `String "https://accounts.google.com"; "sub", `String "비ASCII"]);
     credential (`Assoc ["iss", `String "https://accounts.google.com";
                        "sub", `String "one"; "sub", `String "two"])]
;;

let test_rejects_non_private_or_indirect_oauth_source () =
  with_temp_root
  @@ fun runtime_root ->
  let oauth_source = Filename.concat runtime_root "operator-oauth-token" in
  write_file ~mode:0o644 oauth_source (Masc_test_deps.antigravity_oauth_fixture "secret");
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
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-secret");
  let layout =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"keeper-alpha"
      ~oauth_source
    |> require_ok
  in
  let layout_paths = Runtime_antigravity_home.For_testing.paths layout in
  write_file ~mode:0o600 layout_paths.oauth_path (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "operator-secret");
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
    (Masc_test_deps.antigravity_oauth_fixture ~revision:"native-refresh" "operator-secret")
    (Fs_compat.load_file refreshed_paths.oauth_path);
  check
    string
    "bootstrap source remains external"
    (Masc_test_deps.antigravity_oauth_fixture "operator-secret")
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
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-secret");
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
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-secret");
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
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "secret");
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
  then write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "operator-secret-canary");
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
  let first = seeded_prepare runtime_root in
  let home_dir = Runtime_antigravity_home.home_dir first in
  let library = Filename.concat home_dir "Library" in
  if Sys.file_exists library then Unix.chmod library 0o755
  else Unix.mkdir library 0o755;
  let layout = seeded_prepare runtime_root in
  check string "CLI cache keeps the authoritative generation" home_dir
    (Runtime_antigravity_home.home_dir layout);
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
        ; test_case "native permission and workspace boundaries" `Quick
            test_native_permissions_match_posture_and_workspace
        ; test_case "Keeper account selection and refresh" `Quick
            test_keeper_account_switch_preserves_each_refreshed_home
        ; test_case "corrupt generation refuses without reseed" `Quick
            test_corrupt_generation_never_reseeds_managed_state
        ; test_case "pre-rename pointer failure removes only staged HOME" `Quick
            (test_generation_pointer_failure_retry ~after_rename:false)
        ; test_case "post-rename pointer failure preserves HOME until retry" `Quick
            (test_generation_pointer_failure_retry ~after_rename:true)
        ; test_case "pointerless store reseeds only a fresh seed" `Quick
            test_pointerless_store_reseeds_only_a_fresh_seed
        ; test_case "pointer permissions permit repeated preparation under 0022" `Quick
            test_generation_pointer_is_private_under_standard_umask
        ; test_case "interrupted creation leaves no orphan generation" `Quick
            test_interrupted_generation_creation_leaves_no_orphan
        ; test_case "managed keychain principal matches selection" `Quick
            test_managed_keychain_principal_must_match_selected_generation
        ; test_case "every hierarchy link reconfirms parent sync" `Quick
            test_every_managed_hierarchy_link_reconfirms_parent_sync
        ; test_case "failed parent sync retries visible child" `Quick
            test_failed_parent_sync_retries_visible_child
        ; test_case "preclaim identity preserves active permissions" `Quick
            test_account_identity_preparation_does_not_reset_active_policy
        ; test_case
            "private direct OAuth source"
            `Quick
            test_rejects_non_private_or_indirect_oauth_source
        ; test_case "unknown source identity causes no managed mutation" `Quick
            test_unknown_account_identity_causes_no_managed_mutation
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
