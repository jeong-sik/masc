(* Public file clients and admitted publishers must refuse a FIFO without a
   writer. Forked fixture deadlines make a blocking regression fail finitely. *)
open Alcotest
module D = Masc_domain

let () = Mirage_crypto_rng_unix.use_default ()
let auth_ok = function
  | Ok value -> value
  | Error error -> fail (D.masc_error_to_string error)
let read path = In_channel.with_open_bin path In_channel.input_all

let run_workspace base_path f =
  Eio_main.run @@ fun env ->
  Masc_test_deps.init_eio_clock env;
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Fun.protect ~finally:Fs_compat.clear_fs (fun () ->
    Auth.save_auth_config base_path D.default_auth_config;
    f base_path)

let with_workspace f =
  let base_path = Filename.temp_dir "auth-regular-reader-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> run_workspace base_path f)

let with_fifo_workspace f =
  let base_path = Filename.temp_dir "auth-fifo-reader-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    (* The deadline belongs only to the fixture child, not Auth admission or
       product I/O. There is no FIFO writer and no sleep-based release. *)
    match Unix.fork () with
    | 0 ->
      Sys.set_signal Sys.sigalrm Sys.Signal_default;
      let _previous_alarm_seconds = Unix.alarm 5 in
      (try run_workspace base_path f; exit 0 with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn -> prerr_endline (Printexc.to_string exn); exit 2)
    | pid ->
      let reaped = ref false in
      Fun.protect ~finally:(fun () -> if not !reaped then (
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        let _reaped_child = Unix.waitpid [] pid in ())) (fun () ->
          let _, status = Unix.waitpid [] pid in
          reaped := true;
          match status with
          | Unix.WEXITED 0 -> ()
          | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            fail "Auth file reads must refuse a FIFO without waiting for a writer"))

let check_readers base_path expected =
  check (option string) "public Auth file client" expected
    (Auth.load_raw_token base_path ~agent_name:"reader");
  check (option string) "login persisted file client" expected
    (Auth_login.read_persisted_token ~base_path ~agent_name:"reader")

let test_public_reader_file_states () = with_workspace @@ fun base_path ->
  let path = Auth.raw_token_file base_path "reader" in
  check_readers base_path None;
  let opaque = " opaque-reader-fixture\t" in
  Auth.save_private_text_file path opaque;
  check_readers base_path (Some opaque);
  let target = path ^ ".regular" in
  Unix.rename path target;
  Unix.symlink target path;
  check_readers base_path (Some opaque);
  Unix.unlink path;
  Unix.symlink (path ^ ".missing") path;
  check_readers base_path None;
  Unix.unlink path;
  Unix.mkdir path 0o700;
  check_readers base_path None;
  Unix.rmdir path;
  Auth.save_private_text_file path " \t\r\n";
  check_readers base_path None

let test_public_reader_fifo () = with_fifo_workspace @@ fun base_path ->
  let path = Auth.raw_token_file base_path "reader" in
  Unix.mkfifo path 0o600;
  let occupied = Unix.lstat path in
  check_readers base_path None;
  check bool "the FIFO remains the same occupied file" true
    ((Unix.lstat path).Unix.st_ino = occupied.Unix.st_ino);
  let target = path ^ ".fifo" in
  Unix.rename path target;
  Unix.symlink target path;
  check_readers base_path None;
  Unix.unlink path;
  Auth.save_private_text_file path "regular-reader-recovery";
  check_readers base_path (Some "regular-reader-recovery")

let test_replacement_at_open_refuses_without_blocking () = with_fifo_workspace @@ fun base_path ->
  let path = Auth.raw_token_file base_path "reader" in
  let preserved = path ^ ".preserved" in
  Auth.save_private_text_file path "original-reader-bytes";
  let open_replacement path flags mode =
    Unix.rename path preserved;
    Unix.mkfifo path 0o600;
    Unix.openfile path flags mode in
  (match Auth.Regular_read_for_testing.read_with_open ~open_file:open_replacement path with
   | Error (D.System (D.System_error.ValidationError _)) -> ()
   | Error error -> fail (D.masc_error_to_string error)
   | Ok _ -> fail "replacement FIFO was admitted as a regular file");
  check string "replacement refusal preserves original bytes" "original-reader-bytes" (read preserved);
  Unix.unlink path; Unix.rename preserved path;
  let replace_after_open path flags mode =
    let fd = Unix.openfile path flags mode in
    Unix.rename path preserved;
    Unix.mkfifo path 0o600;
    fd in
  (match Auth.Regular_read_for_testing.read_with_open ~open_file:replace_after_open path with
   | Error (D.System (D.System_error.IoError _)) -> ()
   | Error error -> fail (D.masc_error_to_string error)
   | Ok _ -> fail "replaced pathname admitted bytes from its retired descriptor");
  Unix.unlink path; Unix.rename preserved path;
  check_readers base_path (Some "original-reader-bytes")

let config_refused base_path =
  match Auth.load_auth_config base_path with
  | _config -> fail "occupied unreadable config must not select a default"
  | exception Auth.Auth_config_error { file; reason } ->
    check string "typed config error identifies current path" (Auth.auth_config_file base_path) file;
    check bool "typed config error retains a reason" true (String.length reason > 0)

let test_config_file_states () = with_workspace @@ fun base_path ->
  let file = Auth.auth_config_file base_path in
  check bool "regular config remains readable" true
    (Auth.load_auth_config base_path = D.default_auth_config);
  let target = file ^ ".regular" in
  Unix.rename file target;
  Unix.symlink target file;
  check bool "regular symlink config remains readable" true
    (Auth.load_auth_config base_path = D.default_auth_config);
  Unix.unlink file;
  Unix.symlink (file ^ ".missing") file;
  config_refused base_path;
  Unix.unlink file;
  Unix.mkdir file 0o700;
  config_refused base_path;
  Unix.rmdir file;
  let absent = Auth.load_auth_config base_path in
  check bool "genuine absence retains the exact secure default" true (absent = D.default_auth_config);
  check bool "missing config keeps auth enabled" true absent.enabled;
  check bool "missing config still requires a token" true absent.require_token

let typed_config_refusal = function
  | Error (D.System (D.System_error.ValidationError _)) -> ()
  | Error error -> fail (D.masc_error_to_string error)
  | Ok _ -> fail "admitted publisher must refuse the unreadable current config"

let seed base_path name =
  let credential = auth_ok (Auth.save_file_backed_raw_token_credential base_path
    ~agent_name:name ~role:D.Worker ~raw_token:"regular-read-shared-fixture") in
  let credential = { credential with D.id = Some (D.Credential_id.generate ()) } in
  Auth.save_credential base_path credential;
  credential

let pair_paths base_path (credential : D.agent_credential) =
  [ Auth.credential_file base_path credential.agent_name;
    Auth.raw_token_file base_path credential.agent_name ]
  @ (match credential.id with
     | None -> []
     | Some id -> [ Filename.concat
       (Filename.dirname (Auth.credential_file base_path credential.agent_name))
       (D.Credential_id.to_string id ^ ".json") ])

let check_current_pair base_path name =
  let token = match Auth.load_raw_token base_path ~agent_name:name with
    | Some token -> token | None -> fail "recovered raw token missing" in
  let credential = auth_ok (Auth.verify_token base_path ~agent_name:name ~token) in
  check string "recovered pair authenticates exact raw bytes" credential.token (Auth.sha256_hash token)

let test_config_fifo_publishers () = with_fifo_workspace @@ fun base_path ->
  let first = seed base_path "first" in
  let second = seed base_path "second" in
  let config = Auth.auth_config_file base_path in
  let saved_config = config ^ ".fixture-saved" in
  Unix.rename config saved_config;
  Unix.mkfifo config 0o600;
  let occupied = Unix.lstat config in
  let paths = saved_config :: (pair_paths base_path first @ pair_paths base_path second) in
  let before = List.map read paths in
  config_refused base_path;
  typed_config_refusal (Auth.save_file_backed_raw_token_credential base_path
    ~agent_name:"first" ~role:D.Admin ~raw_token:"regular-read-requested-fixture");
  typed_config_refusal (Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
    ~agent_name:"first" ~role:D.Admin ~token_env_var:"REGULAR_READ_FIXTURE_TOKEN"
    ~token_lifetime:Auth_login.Long_lived ());
  typed_config_refusal (Auth.rotate_shared_tokens base_path);
  check bool "refusal preserves both raw/UUID/name pairs and the saved config" true
    (List.map read paths = before);
  check bool "current configuration remains the same FIFO" true
    ((Unix.lstat config).Unix.st_ino = occupied.Unix.st_ino
      && (Unix.lstat config).Unix.st_kind = Unix.S_FIFO);
  check bool "refused login did not bootstrap a workspace secret" false
    (Sys.file_exists (Auth.workspace_secret_file base_path));
  check bool "refused login did not record a bootstrap Admin" false
    (Sys.file_exists (Filename.concat (Auth.auth_dir base_path) "initial_admin"));
  Unix.unlink config;
  Unix.rename saved_config config;
  (* These real publishers must re-enter admission after each refusal. *)
  let outcomes = auth_ok (Auth.rotate_shared_tokens base_path) in
  (match outcomes with
   | [ { Auth.rotated_agents = [ "first", Ok (); "second", Ok () ]; _ } ] -> ()
   | _ -> fail "repaired config must allow both shared owners to rotate");
  check_current_pair base_path "first";
  check_current_pair base_path "second";
  let _credential = auth_ok (Auth.save_file_backed_raw_token_credential base_path
    ~agent_name:"first" ~role:D.Admin ~raw_token:"regular-read-requested-fixture") in
  let _report = auth_ok (Auth_login.mint ~base_path ~host:"127.0.0.1" ~port:8935
    ~agent_name:"first" ~role:D.Admin ~token_env_var:"REGULAR_READ_FIXTURE_TOKEN"
    ~token_lifetime:Auth_login.Long_lived ()) in
  check_current_pair base_path "first"

let test_cancellation_propagates () = with_workspace @@ fun base_path ->
  Auth.save_private_text_file (Auth.raw_token_file base_path "reader") "regular-reader-fixture";
  let cancelled f =
    try
      Eio.Cancel.sub (fun context -> Eio.Cancel.cancel context Exit; f ());
      false
    with Eio.Cancel.Cancelled _ -> true in
  check bool "public raw read propagates cancellation" true
    (cancelled (fun () -> ignore (Auth.load_raw_token base_path ~agent_name:"reader")));
  check bool "login persisted read propagates cancellation" true
    (cancelled (fun () -> ignore (Auth_login.read_persisted_token ~base_path ~agent_name:"reader")));
  check bool "configuration read propagates cancellation" true
    (cancelled (fun () -> ignore (Auth.load_auth_config base_path)))

let test_canonical_fifo_verification_and_index () =
  List.iter (fun named_fifo -> with_fifo_workspace @@ fun base_path ->
    let first = seed base_path "first" in
    let token = "regular-read-shared-fixture" in
    let _warm = auth_ok (Auth.find_credential_by_token base_path ~token) in
    let named = Auth.credential_file base_path "first" in
    let uuid = match first.id with
      | Some id -> Auth.credential_file base_path (D.Credential_id.to_string id)
      | None -> fail "fixture requires an actual UUID-backed credential" in
    let occupied_paths = if named_fifo then [ named; uuid ] else [ uuid ] in
    let saved = List.map (fun path ->
      let target = path ^ ".fixture-saved" in
      Unix.rename path target; Unix.mkfifo path 0o600; path, target) occupied_paths in
    check bool "public canonical read refuses a nonregular payload" true
      (Auth.load_credential base_path "first" = None);
    let diagnostic = Auth.list_credential_results base_path in
    List.iter (fun path ->
      check bool "diagnostic listing reports occupied FIFO paths without opening them" true
        (List.exists (function
          | Error (Auth.Unreadable_credential {path=failed_path;_}) ->
            String.equal path failed_path
          | Error (Auth.Invalid_credential_expiry _) | Ok _ -> false) diagnostic))
      occupied_paths;
    check bool "warm verification cannot use either unreadable canonical source" true
      (Result.is_error (Auth.verify_token base_path ~agent_name:"first" ~token));
    if named_fifo then (
      check bool "alias setup refuses the occupied nonregular canonical name" true
        (Result.is_error (Auth.ensure_credential_alias base_path
          ~canonical_name:"first" ~alias_name:"short-first"));
      check bool "refused alias is not published" false
        (Sys.file_exists (Auth.credential_file base_path "short-first")));
    (* A real writer invalidates the index, forcing lookup's admitted cold scan. *)
    let _other = auth_ok (Auth.create_token base_path ~agent_name:"other" ~role:D.Worker) in
    check bool "cold scan completes and refuses unreadable first authority" true
      (Result.is_error (Auth.find_credential_by_token base_path ~token));
    check (option string) "raw counterpart is preserved" (Some token)
      (Auth.load_raw_token base_path ~agent_name:"first");
    List.iter (fun (path, target) ->
      check bool "canonical FIFO remains occupied" true ((Unix.lstat path).Unix.st_kind = Unix.S_FIFO);
      Unix.unlink path; Unix.rename target path) saved;
    Auth.save_credential base_path first;
    check_current_pair base_path "first";
    check bool "repaired cold lookup recovers the exact UUID owner" true
      (auth_ok (Auth.find_credential_by_token base_path ~token) = first)) [ false; true ]

let test_hot_metadata_fifo () = with_fifo_workspace @@ fun base_path ->
  let _worker = seed base_path "first" in
  let admin = Filename.concat (Auth.auth_dir base_path) "initial_admin" in
  let internal = Filename.concat (Auth.auth_dir base_path) "internal_keeper.token.hash" in
  let secret = Auth.workspace_secret_file base_path in
  List.iter (fun path -> Unix.mkfifo path 0o600) [ admin; internal; secret ];
  check (option string) "startup Admin read refuses FIFO" None (Auth.read_initial_admin base_path);
  check bool "internal token verification refuses FIFO" false
    (Auth.verify_internal_keeper_token base_path ~token:"internal-reader-fixture");
  check bool "uncached workspace secret verification refuses FIFO" false
    (Auth.verify_workspace_secret base_path ~cached_hash:None "workspace-reader-fixture");
  let () = auth_ok (Auth.check_permission base_path ~agent_name:"first"
    ~token:(Some "regular-read-shared-fixture") ~permission:D.CanReadState) in
  List.iter (fun path ->
    check bool "unreadable metadata is preserved" true ((Unix.lstat path).Unix.st_kind = Unix.S_FIFO);
    Unix.unlink path) [ admin; internal; secret ];
  Auth.save_private_text_file admin "operator-reader-fixture";
  Auth.save_private_text_file internal (Auth.sha256_hash "internal-reader-fixture");
  Auth.save_private_text_file secret (Auth.sha256_hash "workspace-reader-fixture");
  check (option string) "repaired startup Admin is readable" (Some "operator-reader-fixture")
    (Auth.read_initial_admin base_path);
  check bool "repaired internal token authenticates" true
    (Auth.verify_internal_keeper_token base_path ~token:"internal-reader-fixture");
  check bool "repaired uncached workspace secret authenticates" true
    (Auth.verify_workspace_secret base_path ~cached_hash:None "workspace-reader-fixture");
  let () = auth_ok (Auth.check_permission base_path ~agent_name:"recovery-fixture"
    ~token:(Some "workspace-reader-fixture") ~permission:D.CanAdmin) in
  let () = auth_ok (Auth.check_permission base_path ~agent_name:"internal-fixture"
    ~token:(Some "internal-reader-fixture") ~permission:D.CanReadState) in
  ()

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> Unix.putenv name value | None -> Unix.unsetenv name) f

let oauth_ok = function
  | Ok value -> value | Error error -> fail (Auth_oauth.show_error error)

let issue_oauth_pair base_path bootstrap resource =
  let redirect_uri = "http://127.0.0.1:43123/callback/regular-reader-fixture" in
  let client = oauth_ok (Auth_oauth.register_client ~base_path
    ~client_name:(Some "Regular reader fixture") ~redirect_uris:[ redirect_uri ]) in
  let verifier = String.make 43 'v' in
  let request = oauth_ok (Auth_oauth.validate_authorization_request ~base_path
    ~expected_resource:resource ~response_type:(Some "code") ~client_id:(Some client.client_id)
    ~redirect_uri:(Some redirect_uri) ~resource:(Some resource) ~scope:(Some "mcp:tools")
    ~state:None ~code_challenge:(Some (Auth_oauth.pkce_s256 verifier))
    ~code_challenge_method:(Some "S256")) in
  let code = oauth_ok (Auth_oauth.issue_authorization_code ~base_path ~request
    ~bootstrap_credential:bootstrap) in
  oauth_ok (Auth_oauth.exchange_authorization_code ~base_path ~expected_resource:resource
    ~code ~client_id:client.client_id ~redirect_uri ~resource:(Some resource) ~code_verifier:verifier)

let test_oauth_fifo_verification () =
  List.iter (fun access_fifo -> with_fifo_workspace @@ fun base_path ->
    with_env "MASC_OAUTH_ENABLED" "1" (fun () ->
      let bootstrap = seed base_path "first" in
      let resource = "http://127.0.0.1:8935/mcp" in
      let pair = issue_oauth_pair base_path bootstrap resource in
      let oauth_root = Filename.concat (Auth.auth_dir base_path) "oauth" in
      let access = Filename.concat (Filename.concat oauth_root "access_tokens")
        (Auth.sha256_hash pair.access_token ^ ".json") in
      let families = Filename.concat oauth_root "families" in
      let family = match Array.to_list (Sys.readdir families) with
        | [ name ] -> Filename.concat families name
        | [] | _ :: _ -> fail "fixture must issue exactly one OAuth family" in
      let occupied = if access_fifo then access else family in
      let saved = occupied ^ ".fixture-saved" in
      let other = if access_fifo then family else access in
      let before = read occupied, read other, List.map read (pair_paths base_path bootstrap) in
      let lookup () = Auth_oauth.with_expected_resource resource (fun () ->
        Auth.find_credential_by_token base_path ~token:pair.access_token) in
      let _valid = auth_ok (lookup ()) in
      Unix.rename occupied saved; Unix.mkfifo occupied 0o600;
      (match lookup () with
       | Error (D.System (D.System_error.IoError _)) -> ()
       | Error error -> fail (D.masc_error_to_string error)
       | Ok _ -> fail "OAuth FIFO store failure must not fall through to static credentials");
      check bool "OAuth refusal preserves record counterpart and bootstrap pair" true
        ((read saved, read other, List.map read (pair_paths base_path bootstrap)) = before);
      check bool "OAuth FIFO remains occupied" true ((Unix.lstat occupied).Unix.st_kind = Unix.S_FIFO);
      Unix.unlink occupied; Unix.rename saved occupied;
      let recovered = auth_ok (lookup ()) in
      check string "repaired OAuth store lock remains usable" bootstrap.agent_name recovered.agent_name))
    [ true; false ]

let () = run "Auth regular file read authority" [
  "file clients", [
    test_case "regular, symlink, dangling, directory and blank raw tokens" `Quick test_public_reader_file_states;
    test_case "public readers refuse a FIFO without a writer" `Quick test_public_reader_fifo;
    test_case "replacement before and after open cannot block or admit retired bytes" `Quick test_replacement_at_open_refuses_without_blocking;
    test_case "strict config presence and secure missing defaults" `Quick test_config_file_states;
    test_case "config FIFO refuses actual publishers and repaired admission works" `Quick test_config_fifo_publishers;
    test_case "expected read errors do not swallow cancellation" `Quick test_cancellation_propagates;
    test_case "named/UUID FIFO verification, alias and cold index recover" `Quick test_canonical_fifo_verification_and_index;
    test_case "startup Admin and hot internal/secret FIFO paths recover" `Quick test_hot_metadata_fifo;
    test_case "OAuth-enabled access/family FIFO verification recovers" `Quick test_oauth_fifo_verification;
  ]
]
