(** Auth Module Tests *)

(* Initialize RNG for crypto operations *)
let () = Mirage_crypto_rng_unix.use_default ()

open Alcotest
module Auth = Masc_mcp.Auth
module Tool_spec = Masc_mcp.Tool_spec
module Tool_dispatch = Masc_mcp.Tool_dispatch
module Types = Types

(* Setup a temp directory for testing *)
let setup_test_room () =
  (* Use PID + timestamp for deterministic unique dir *)
  let unique_id = Printf.sprintf "masc-auth-test-%d-%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.)) in
  let tmp = Filename.concat (Filename.get_temp_dir_name ()) unique_id in
  Unix.mkdir tmp 0o755;
  let masc_dir = Filename.concat tmp Common.masc_dirname in
  Unix.mkdir masc_dir 0o755;
  tmp

let cleanup_test_room dir =
  (* Simple recursive delete *)
  let rec rm_rf path =
    if Sys.is_directory path then begin
      Array.iter (fun f -> rm_rf (Filename.concat path f)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Sys.remove path
  in
  try rm_rf dir with _ -> ()

let permission_bits path =
  (Unix.stat path).Unix.st_perm land 0o777

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  try
    let result = f () in
    (match previous with
     | Some v -> Unix.putenv name v
     | None -> Unix.putenv name "");
    result
  with exn ->
    (match previous with
     | Some v -> Unix.putenv name v
     | None -> Unix.putenv name "");
    raise exn

let with_eio_runtime f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Fun.protect
    ~finally:(fun () ->
      Eio_guard.disable ();
      Fs_compat.clear_fs ())
    f

let capture_stderr f =
  let pipe_read, pipe_write = Unix.pipe () in
  let saved_stderr = Unix.dup Unix.stderr in
  Unix.dup2 pipe_write Unix.stderr;
  Unix.close pipe_write;
  (try f () with _ -> ());
  flush stderr;
  Unix.dup2 saved_stderr Unix.stderr;
  Unix.close saved_stderr;
  Unix.set_nonblock pipe_read;
  let buf = Buffer.create 256 in
  let tmp = Bytes.create 256 in
  let rec read_all () =
    match Unix.read pipe_read tmp 0 256 with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf tmp 0 n;
        read_all ()
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    | exception _ -> ()
  in
  read_all ();
  Unix.close pipe_read;
  Buffer.contents buf

let strict_unknown_tool_denial_count ~agent_name ~tool_class =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_auth_strict_unknown_tool_denials
    ~labels:[ ("agent_name", agent_name); ("tool_class", tool_class) ]
    ()

let keeper_strict_auth_regression_tools =
  [
    "keeper_shell";
    "keeper_bash";
    "keeper_task_claim";
    "keeper_fs_read";
    "keeper_board_search";
    "keeper_tools_list";
  ]

(* ============================================ *)
(* Token generation tests                       *)
(* ============================================ *)

let test_token_generation () =
  let token = Auth.generate_token () in
  check int "token length is 64 hex chars" 64 (String.length token);
  check bool "token is hex" true
    (String.for_all (fun c ->
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
    ) token)

let test_sha256_hash () =
  let hash1 = Auth.sha256_hash "hello" in
  let hash2 = Auth.sha256_hash "hello" in
  let hash3 = Auth.sha256_hash "world" in
  check string "same input same hash" hash1 hash2;
  check bool "different input different hash" true (hash1 <> hash3);
  check int "hash length is 64 chars" 64 (String.length hash1)

(* ============================================ *)
(* Auth config tests                            *)
(* ============================================ *)

let test_default_auth_config () =
  let cfg = Types.default_auth_config in
  check bool "auth disabled by default" false cfg.enabled;
  check bool "token not required by default" false cfg.require_token;
  check int "24hr expiry by default" 24 cfg.token_expiry_hours

let test_save_load_auth_config () =
  let dir = setup_test_room () in
  let cfg = { Types.default_auth_config with enabled = true; require_token = true } in
  Auth.save_auth_config dir cfg;
  let loaded = Auth.load_auth_config dir in
  check bool "enabled persisted" true loaded.enabled;
  check bool "require_token persisted" true loaded.require_token;
  cleanup_test_room dir

let test_save_load_auth_config_in_eio_runtime () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      with_eio_runtime (fun () ->
        let cfg = { Types.default_auth_config with enabled = true; require_token = true } in
        Auth.save_auth_config dir cfg;
        let loaded = Auth.load_auth_config dir in
        check bool "enabled persisted in eio" true loaded.enabled;
        check bool "require_token persisted in eio" true loaded.require_token))

let test_auth_config_saved_private () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      let cfg = { Types.default_auth_config with enabled = true } in
      Auth.save_auth_config dir cfg;
      check int "auth config mode 0600" 0o600
        (permission_bits (Auth.auth_config_file dir)))

(* ============================================ *)
(* Credential management tests                  *)
(* ============================================ *)

let test_create_credential () =
  let dir = setup_test_room () in
  let result = Auth.create_token dir ~agent_name:"claude" ~role:Types.Worker in
  cleanup_test_room dir;
  match result with
  | Ok (raw_token, cred) ->
      check string "agent_name matches" "claude" cred.agent_name;
      check bool "role is Worker" true (cred.role = Types.Worker);
      check int "raw token is 64 chars" 64 (String.length raw_token);
      check int "stored token is 64 chars" 64 (String.length cred.token)
  | Error _ ->
      fail "create_token should succeed"

let test_credential_saved_private () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      match Auth.create_token dir ~agent_name:"claude" ~role:Types.Worker with
      | Ok _ ->
          check int "credential mode 0600" 0o600
            (permission_bits (Auth.credential_file dir "claude"))
      | Error e ->
          fail
            (Printf.sprintf "create_token should succeed: %s"
               (Types.masc_error_to_string e)))

let test_room_secret_saved_private () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore (Auth.init_room_secret dir);
      check int "room secret mode 0600" 0o600
        (permission_bits (Auth.room_secret_file dir)))

let test_verify_token () =
  let dir = setup_test_room () in
  let create_result = Auth.create_token dir ~agent_name:"claude" ~role:Types.Admin in
  let verify_result = match create_result with
    | Ok (raw_token, _) -> Auth.verify_token dir ~agent_name:"claude" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match create_result, verify_result with
  | Ok _, Ok cred ->
      check string "verified agent matches" "claude" cred.agent_name;
      check bool "verified role matches" true (cred.role = Types.Admin)
  | Ok _, Error e ->
      fail (Printf.sprintf "verify_token should succeed: %s" (Types.masc_error_to_string e))
  | Error _, _ ->
      fail "create_token should succeed"

let test_verify_wrong_token () =
  let dir = setup_test_room () in
  let create_result = Auth.create_token dir ~agent_name:"claude" ~role:Types.Worker in
  let verify_result = match create_result with
    | Ok _ -> Auth.verify_token dir ~agent_name:"claude" ~token:"wrongtoken"
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match create_result, verify_result with
  | Ok _, Ok _ ->
      fail "verify_token should fail with wrong token"
  | Ok _, Error (Types.InvalidToken _) ->
      (* Expected *)
      ()
  | Ok _, Error e ->
      fail (Printf.sprintf "wrong error type: %s" (Types.masc_error_to_string e))
  | Error _, _ ->
      fail "create_token should succeed"

let test_verify_token_reports_token_owner_on_agent_mismatch () =
  let dir = setup_test_room () in
  let create_result = Auth.create_token dir ~agent_name:"codex" ~role:Types.Worker in
  let verify_result =
    match create_result with
    | Ok (raw_token, _) -> Auth.verify_token dir ~agent_name:"gemini" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match create_result, verify_result with
  | Ok _, Error (Types.Unauthorized msg) ->
      check string "mismatch message"
        "🔐 Unauthorized: No credential found for gemini (bearer token belongs to codex)"
        (Types.masc_error_to_string (Types.Unauthorized msg))
  | Ok _, Ok _ ->
      fail "verify_token should fail when token owner and requested agent differ"
  | Ok _, Error e ->
      fail
        (Printf.sprintf "wrong error type for mismatch: %s"
           (Types.masc_error_to_string e))
  | Error _, _ ->
      fail "create_token should succeed"

let test_verify_token_allows_generated_alias_for_token_owner_prefix () =
  let dir = setup_test_room () in
  let create_result = Auth.create_token dir ~agent_name:"qa-king" ~role:Types.Worker in
  let verify_result =
    match create_result with
    | Ok (raw_token, _) ->
        Auth.verify_token dir ~agent_name:"qa-king-warm-heron" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match create_result, verify_result with
  | Ok _, Ok cred ->
      check string "token owner credential returned" "qa-king" cred.agent_name;
      check bool "role preserved" true (cred.role = Types.Worker)
  | Ok _, Error e ->
      fail
        (Printf.sprintf "generated alias should reuse owner token: %s"
           (Types.masc_error_to_string e))
  | Error _, _ ->
      fail "create_token should succeed"

let test_resolve_agent_from_token () =
  let dir = setup_test_room () in
  let create_result = Auth.create_token dir ~agent_name:"resolver" ~role:Types.Worker in
  let resolve_result =
    match create_result with
    | Ok (raw_token, _) -> Auth.resolve_agent_from_token dir ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match resolve_result with
  | Ok agent_name -> check string "resolved agent" "resolver" agent_name
  | Error e -> fail (Types.masc_error_to_string e)

let test_list_credentials () =
  let dir = setup_test_room () in
  let _ = Auth.create_token dir ~agent_name:"claude" ~role:Types.Admin in
  let _ = Auth.create_token dir ~agent_name:"gemini" ~role:Types.Worker in
  let _ = Auth.create_token dir ~agent_name:"codex" ~role:Types.Worker in
  let creds = Auth.list_credentials dir in
  cleanup_test_room dir;
  check int "3 credentials" 3 (List.length creds)

let test_delete_credential () =
  let dir = setup_test_room () in
  let _ = Auth.create_token dir ~agent_name:"claude" ~role:Types.Worker in
  Auth.delete_credential dir "claude";
  let creds = Auth.list_credentials dir in
  cleanup_test_room dir;
  check int "0 credentials after delete" 0 (List.length creds)

let test_load_credential_redirect_stub () =
  (* UUID-backed credentials write a redirect stub so legacy exact-name
     lookups continue to work after Phase-3 migration. *)
  let dir = setup_test_room () in
  let id = Types.Credential_id.generate () in
  let cred : Types.agent_credential =
    {
      id = Some id;
      agent_id = None;
      agent_name = "adversary";
      token = "hashed-token";
      role = Types.Worker;
      created_at = "2026-01-01T00:00:00Z";
      expires_at = None;
    }
  in
  Auth.save_credential dir cred;
  let stub_hit = Auth.load_credential dir "adversary" in
  let uuid_hit = Auth.load_credential dir (Types.Credential_id.to_string id) in
  cleanup_test_room dir;
  (match stub_hit with
   | Some loaded when loaded.agent_name = "adversary" -> ()
   | _ -> fail "redirect stub should resolve to UUID-backed credential");
  (match uuid_hit with
   | Some loaded when loaded.agent_name = "adversary" -> ()
   | _ -> fail "direct UUID lookup should resolve")

let test_delete_uuid_backed_credential_removes_redirect_target () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      let id = Types.Credential_id.generate () in
      let raw_token = "uuid-backed-secret" in
      let cred : Types.agent_credential =
        {
          id = Some id;
          agent_id = None;
          agent_name = "adversary";
          token = Auth.sha256_hash raw_token;
          role = Types.Worker;
          created_at = "2026-01-01T00:00:00Z";
          expires_at = None;
        }
      in
      Auth.save_credential dir cred;
      (match Auth.verify_token dir ~agent_name:"adversary" ~token:raw_token with
       | Ok _ -> ()
       | Error e ->
           fail
             (Printf.sprintf
                "uuid-backed credential should verify before delete: %s"
                (Types.masc_error_to_string e)));
      Auth.delete_credential dir "adversary";
      check bool "agent stub removed" true
        (Option.is_none (Auth.load_credential dir "adversary"));
      check bool "uuid target removed" true
        (Option.is_none
           (Auth.load_credential dir (Types.Credential_id.to_string id)));
      (match Auth.find_credential_by_token dir ~token:raw_token with
       | Error (Types.InvalidToken _) -> ()
       | Error e ->
           fail
             (Printf.sprintf
                "expected deleted token to be invalid: %s"
                (Types.masc_error_to_string e))
       | Ok cred ->
           fail (Printf.sprintf "deleted token still resolves to %s" cred.agent_name));
      check int "0 credentials after uuid-backed delete" 0
        (List.length (Auth.list_credentials dir)))

let test_load_credential_exact_wins_over_fallback () =
  (* If both the nickname file and the prefix file exist, the exact
     match wins so a per-nickname override remains possible. *)
  let dir = setup_test_room () in
  let _ = Auth.create_token dir ~agent_name:"adversary" ~role:Types.Worker in
  let _ = Auth.create_token dir ~agent_name:"adversary-fair-tapir" ~role:Types.Admin in
  let resolved = Auth.load_credential dir "adversary-fair-tapir" in
  cleanup_test_room dir;
  match resolved with
  | Some cred when cred.agent_name = "adversary-fair-tapir" && cred.role = Types.Admin -> ()
  | Some cred ->
      fail (Printf.sprintf "unexpected resolution: %s/%s" cred.agent_name
              (match cred.role with Worker -> "Worker" | Admin -> "Admin"))
  | None -> fail "exact match should resolve"

let test_extract_agent_type_prefix_keeper_aliases () =
  check (option string) "keeper simple alias" (Some "sangsu")
    (Auth.extract_agent_type_prefix "keeper-sangsu-agent");
  check (option string) "keeper hyphenated alias" (Some "masc-improver")
    (Auth.extract_agent_type_prefix "keeper-masc-improver-agent");
  check (option string) "generated nickname" (Some "adversary")
    (Auth.extract_agent_type_prefix "adversary-fair-tapir");
  check (option string) "hyphenated generated nickname" (Some "qa-king")
    (Auth.extract_agent_type_prefix "qa-king-warm-heron");
  check (option string) "hyphenated generated nickname unique" (Some "qa-king")
    (Auth.extract_agent_type_prefix "qa-king-warm-heron-a3b2");
  check (option string) "plain name stays plain" (Some "sangsu")
    (Auth.extract_agent_type_prefix "sangsu");
  check (option string) "two segment keeper fallback unchanged" (Some "keeper")
    (Auth.extract_agent_type_prefix "keeper-sangsu")

let test_verify_token_keeper_exact_match () =
  (* UUID-based storage removes nickname-prefix collapse.  Keeper
     credentials must be looked up by their exact agent_name. *)
  let dir = setup_test_room () in
  let result =
    match Auth.ensure_keeper_credential dir ~agent_name:"keeper-sangsu-agent" with
    | Ok (raw_token, _) ->
        Auth.verify_token dir ~agent_name:"keeper-sangsu-agent" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok cred ->
      check string "keeper credential exact match" "keeper-sangsu-agent" cred.agent_name
  | Error e ->
      fail
        (Printf.sprintf
           "keeper credential should verify with exact agent_name: %s"
           (Types.masc_error_to_string e))

(* Was: this test validated a legacy fallback where a bare-form
   credential ("sangsu") was accepted as a verification source for a
   canonical lookup ("keeper-sangsu-agent"). That fallback was the
   mechanism by which dual-identity credentials silently coexisted --
   any path that minted a bare credential created a second valid
   identity for the same keeper.

   PR-3a self-heals dual-identity: ensure_keeper_credential archives
   the bare-form credential when its token differs from the canonical.
   The bare token therefore must NOT verify against the canonical
   name after bootstrap. Spec: AuthIdentityFSM.tla I1
   IdentityBindsToken (a token must bind to exactly one principal). *)
let test_verify_token_keeper_alias_archives_dual_identity_bare () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      match Auth.create_token dir ~agent_name:"sangsu" ~role:Types.Worker with
      | Error e ->
          fail
            (Printf.sprintf "stable keeper token creation failed: %s"
               (Types.masc_error_to_string e))
      | Ok (stale_bare_token, _) -> (
          match
            Auth.ensure_keeper_credential dir
              ~agent_name:"keeper-sangsu-agent"
          with
          | Error e ->
              fail
                (Printf.sprintf "keeper credential bootstrap failed: %s"
                   (Types.masc_error_to_string e))
          | Ok _ -> (
              check bool "canonical credential exists" true
                (Option.is_some
                   (Auth.load_credential dir "keeper-sangsu-agent"));
              (* PR-3a behavior: bare credential is archived, the bare
                 token is now stale and must not authenticate. *)
              match
                Auth.verify_token dir ~agent_name:"keeper-sangsu-agent"
                  ~token:stale_bare_token
              with
              | Ok cred ->
                  fail
                    (Printf.sprintf
                       "stale bare token must NOT verify against canonical \
                        after PR-3a self-heal (got cred owner=%s)"
                       cred.agent_name)
              | Error _ -> ())))

let test_load_credential_missing_keeper_alias_stays_quiet () =
  let dir = setup_test_room () in
  let resolved, stderr_output =
    Fun.protect
      ~finally:(fun () -> cleanup_test_room dir)
      (fun () ->
        let resolved = ref None in
        let stderr_output =
          capture_stderr (fun () ->
            resolved := Auth.load_credential dir "keeper-sangsu-agent")
        in
        (!resolved, stderr_output))
  in
  check (option string) "missing keeper alias returns none" None
    (Option.map (fun cred -> cred.Types.agent_name) resolved);
  check string "missing keeper alias emits no parse noise" ""
    (String.trim stderr_output)

let test_verify_token_dashboard_legacy_alias_fallback () =
  let dir = setup_test_room () in
  let result =
    match Auth.create_token dir ~agent_name:"dashboard-dev" ~role:Types.Admin with
    | Ok (raw_token, _) ->
        Auth.verify_token dir ~agent_name:"dashboard" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok cred ->
      check string "legacy dashboard token owner" "dashboard-dev" cred.agent_name
  | Error e ->
      fail
        (Printf.sprintf
           "dashboard should accept legacy dashboard-dev credential: %s"
           (Types.masc_error_to_string e))

let test_save_raw_token_credential_uses_provided_token () =
  let dir = setup_test_room () in
  let raw_token = "fixed-admin-token" in
  let save_result =
    Auth.save_raw_token_credential dir ~agent_name:"bootstrap-admin"
      ~role:Types.Admin ~raw_token
  in
  let verify_result =
    match save_result with
    | Ok _ ->
        Auth.verify_token dir ~agent_name:"bootstrap-admin" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match verify_result with
  | Ok cred ->
      check string "saved credential owner" "bootstrap-admin" cred.agent_name;
      check bool "saved credential role is admin" true (cred.role = Types.Admin)
  | Error e ->
      fail
        (Printf.sprintf
           "provided raw token should verify after save_raw_token_credential: %s"
           (Types.masc_error_to_string e))

let test_ensure_keeper_credential_uses_per_keeper_token () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      let ensure_result =
        with_env "MASC_MCP_TOKEN" "" (fun () ->
          Auth.ensure_keeper_credential dir ~agent_name:"keeper-masc-improver-agent")
      in
      match ensure_result with
      | Ok (raw_token, cred) ->
          let raw_token_path =
            Filename.concat (Auth.auth_dir dir)
              "keeper-masc-improver-agent.token"
          in
          check string "keeper credential exact name" "keeper-masc-improver-agent" cred.agent_name;
          check bool "keeper credential has uuid id" true (Option.is_some cred.id);
          check bool "keeper credential is worker" true (cred.role = Types.Worker);
          check bool "keeper bearer is not the shared internal token" false
            (Auth.verify_internal_keeper_token dir ~token:raw_token);
          check bool "internal keeper token hash persisted" true
            (Sys.file_exists (Auth.internal_keeper_token_hash_file dir));
          check bool "persisted raw token file created" true
            (Sys.file_exists raw_token_path);
          check string "raw token hashes to keeper credential"
            cred.token (Auth.sha256_hash raw_token);
          check bool "keeper credential persisted by exact name" true
            (Option.is_some (Auth.load_credential dir "keeper-masc-improver-agent"));
          check bool "no normalized keeper credential persisted" true
            (Option.is_none (Auth.load_credential dir "masc-improver"));
          (match
             Auth.verify_token dir ~agent_name:"keeper-masc-improver-agent"
               ~token:raw_token
           with
           | Ok verified ->
               check string "keeper bearer verifies exact agent"
                 "keeper-masc-improver-agent" verified.agent_name
           | Error e ->
               fail
                 (Printf.sprintf
                    "per-keeper bearer token should verify: %s"
                    (Types.masc_error_to_string e)))
      | Error e ->
          fail
            (Printf.sprintf
               "ensure_keeper_credential should mint a per-keeper token: %s"
               (Types.masc_error_to_string e)))

(* PR-3a regression guards: ensure_keeper_credential self-heals
   dual-identity by archiving any pre-existing bare-form credential
   whose token differs from the canonical. Spec: AuthIdentityFSM.tla
   I1 IdentityBindsToken. *)

let archive_dir_of dir = Filename.concat (Auth.auth_dir dir) ".archive"

let archive_contains dir filename =
  let archive = archive_dir_of dir in
  if not (Sys.file_exists archive) then false
  else
    let stamps = Sys.readdir archive in
    Array.exists
      (fun stamp ->
        let stamp_path = Filename.concat archive stamp in
        Sys.is_directory stamp_path
        && Array.exists (String.equal filename) (Sys.readdir stamp_path))
      stamps

let test_ensure_keeper_credential_archives_dual_identity_bare () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore
        (Auth.enable_auth dir ~require_token:true
           ~agent_name:"bootstrap-admin");
      (* Historical residue: a bare-form credential created by an older
         path (e.g., pre-#10440 boot, CLI login) with its own token. *)
      let _ =
        match Auth.create_token dir ~agent_name:"sangsu" ~role:Types.Worker with
        | Ok r -> r
        | Error e -> fail (Types.masc_error_to_string e)
      in
      let bare_path = Auth.credential_file dir "sangsu" in
      check bool "bare credential pre-exists" true (Sys.file_exists bare_path);
      (* Now ensure the canonical is created — should self-heal. *)
      (match
         Auth.ensure_keeper_credential dir
           ~agent_name:"keeper-sangsu-agent"
       with
       | Ok _ -> ()
       | Error e -> fail (Types.masc_error_to_string e));
      check bool "bare credential moved out of agents/" false
        (Sys.file_exists bare_path);
      check bool "bare credential archived" true
        (archive_contains dir "sangsu.json");
      let canonical_path =
        Auth.credential_file dir "keeper-sangsu-agent"
      in
      check bool "canonical credential remains" true
        (Sys.file_exists canonical_path))

let test_ensure_keeper_credential_no_archive_when_no_bare () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      ignore
        (Auth.enable_auth dir ~require_token:true
           ~agent_name:"bootstrap-admin");
      (* Clean state: only the canonical is created. No bare residue. *)
      (match
         Auth.ensure_keeper_credential dir
           ~agent_name:"keeper-sangsu-agent"
       with
       | Ok _ -> ()
       | Error e -> fail (Types.masc_error_to_string e));
      let archive = archive_dir_of dir in
      check bool "no archive directory created on clean state" false
        (Sys.file_exists archive))

let test_ensure_keeper_credential_reuses_persisted_raw_token_when_env_mismatched () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      let first_result =
        with_env "MASC_MCP_TOKEN" "" (fun () ->
          Auth.ensure_keeper_credential dir ~agent_name:"keeper-masc-improver-agent")
      in
      let raw_token_path =
        Filename.concat (Auth.auth_dir dir) "keeper-masc-improver-agent.token"
      in
      let shared_raw_token = "shared-codex-token" in
      let _ =
        Auth.save_raw_token_credential dir ~agent_name:"codex-mcp-client"
          ~role:Types.Admin ~raw_token:shared_raw_token
      in
      let reused_result =
        with_env "MASC_MCP_TOKEN" shared_raw_token (fun () ->
          Auth.ensure_keeper_credential dir ~agent_name:"keeper-masc-improver-agent")
      in
      match first_result, reused_result with
      | Ok (first_raw_token, first_cred), Ok (reused_raw_token, reused_cred) ->
          check bool "persisted raw token file created" true
            (Sys.file_exists raw_token_path);
          check int "persisted raw token file mode 0600" 0o600
            (permission_bits raw_token_path);
          check string "first credential uses exact keeper name" "keeper-masc-improver-agent"
            first_cred.agent_name;
          check string "reused credential keeps exact keeper name" "keeper-masc-improver-agent"
            reused_cred.agent_name;
          check string "persisted keeper raw token reused" first_raw_token
            reused_raw_token
      | Error e, _ | _, Error e ->
          fail
            (Printf.sprintf
               "ensure_keeper_credential should reuse persisted keeper token: %s"
               (Types.masc_error_to_string e)))

let test_ensure_keeper_credential_reuses_uuid () =
  let dir = setup_test_room () in
  Fun.protect
    ~finally:(fun () -> cleanup_test_room dir)
    (fun () ->
      let result =
        with_env "MASC_INTERNAL_MCP_TOKEN" "shared-keeper-token" (fun () ->
          match
            Auth.ensure_keeper_credential dir ~agent_name:"keeper-masc-improver-agent"
          with
          | Error e -> Error e
          | Ok (_, first_cred) -> (
              match
                Auth.ensure_keeper_credential dir
                  ~agent_name:"keeper-masc-improver-agent"
              with
              | Error e -> Error e
              | Ok (_, second_cred) -> Ok (first_cred, second_cred)))
      in
      match result with
      | Error e ->
          fail
            (Printf.sprintf
               "ensure_keeper_credential should keep a stable UUID: %s"
               (Types.masc_error_to_string e))
      | Ok (first_cred, second_cred) -> (
          match first_cred.id, second_cred.id with
          | Some first_id, Some second_id ->
              check string "keeper credential UUID stable"
                (Types.Credential_id.to_string first_id)
                (Types.Credential_id.to_string second_id);
              check int "one logical keeper credential" 1
                (List.length (Auth.list_credentials dir))
          | _ -> fail "keeper credentials should be UUID-backed"))

(* ============================================ *)
(* Permission tests                             *)
(* ============================================ *)

let test_worker_permissions () =
  check bool "worker can read" true
    (Types.has_permission Types.Worker Types.CanReadState);
  check bool "worker can claim" true
    (Types.has_permission Types.Worker Types.CanClaimTask);
  check bool "worker cannot init" false
    (Types.has_permission Types.Worker Types.CanInit)

let test_admin_permissions () =
  check bool "admin can read" true
    (Types.has_permission Types.Admin Types.CanReadState);
  check bool "admin can init" true
    (Types.has_permission Types.Admin Types.CanInit);
  check bool "admin can reset" true
    (Types.has_permission Types.Admin Types.CanReset);
  check bool "admin can admin" true
    (Types.has_permission Types.Admin Types.CanAdmin)

(* ============================================ *)
(* Authorization tests                          *)
(* ============================================ *)

let test_auth_disabled_allows_all () =
  let dir = setup_test_room () in
  (* Auth disabled by default *)
  let result = Auth.check_permission dir ~agent_name:"anyone" ~token:None ~permission:Types.CanInit in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error _ -> fail "should allow when auth disabled"

let test_auth_enabled_requires_token () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let result = Auth.check_permission dir ~agent_name:"claude" ~token:None ~permission:Types.CanClaimTask in
  cleanup_test_room dir;
  match result with
  | Ok () -> fail "should require token"
  | Error (Types.Unauthorized _) -> ()
  | Error _ -> fail "wrong error type"

let test_auth_enabled_with_valid_token () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"claude" ~role:Types.Worker in
  let check_result = match create_result with
    | Ok (raw_token, _) ->
        Auth.check_permission dir ~agent_name:"claude" ~token:(Some raw_token) ~permission:Types.CanClaimTask
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match check_result with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_permission_denied_for_worker_admin_action () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker in
  let check_result = match create_result with
    | Ok (raw_token, _) ->
        Auth.check_permission dir ~agent_name:"worker_agent" ~token:(Some raw_token) ~permission:Types.CanInit
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match check_result with
  | Ok () -> fail "worker should not get admin action"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Printf.sprintf "wrong error: %s" (Types.masc_error_to_string e))

let test_authorize_unknown_masc_tool_strict_worker_allowed () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker in
  let result =
    match create_result with
    | Ok (raw_token, _) ->
        with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
            Auth.authorize_tool dir ~agent_name:"worker_agent" ~token:(Some raw_token)
              ~tool_name:"masc_unknown_tool")
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_authorize_unknown_non_masc_tool_strict_denied () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker in
  let before =
    strict_unknown_tool_denial_count
      ~agent_name:"worker_agent" ~tool_class:"external"
  in
  let result =
    match create_result with
    | Ok (raw_token, _) ->
        with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
            Auth.authorize_tool dir ~agent_name:"worker_agent" ~token:(Some raw_token)
              ~tool_name:"external_unknown_tool")
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> fail "unknown non-masc tool should be denied in strict mode"
  | Error (Types.Forbidden _) ->
      check (float 0.0001) "denial counter increments"
        (before +. 1.0)
        (strict_unknown_tool_denial_count
           ~agent_name:"worker_agent" ~tool_class:"external")
  | Error e -> fail (Printf.sprintf "wrong error: %s" (Types.masc_error_to_string e))

let test_authorize_unknown_canonical_tool_strict_worker_allowed () =
  (* #10205 finding 1: lock the [internal_tool_prefixes] vocabulary
     (masc_, decision., experiment., client.) so a future refactor
     that drops one silently is caught here.  Each prefix's
     unmapped tool must pass strict-mode check for a Worker. *)
  let prefixes_with_unlisted_tool = [
    "masc_unlisted_tool";
    "decision.unlisted_tool";
    "experiment.unlisted_tool";
    "client.unlisted_tool";
  ] in
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker in
  let result =
    match create_result with
    | Ok (raw_token, _) ->
        with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
            List.fold_left
              (fun acc tool_name ->
                 match acc with
                 | Error _ as e -> e
                 | Ok () ->
                     Auth.authorize_tool dir ~agent_name:"worker_agent"
                       ~token:(Some raw_token) ~tool_name)
              (Ok ())
              prefixes_with_unlisted_tool)
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_authorize_known_keeper_tool_strict_worker_allowed () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result =
    Auth.create_token dir ~agent_name:"keeper-analyst-agent" ~role:Types.Worker
  in
  let result =
    match create_result with
    | Ok (raw_token, _) ->
        with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
            List.fold_left
              (fun acc tool_name ->
                 match acc with
                 | Error _ as e -> e
                 | Ok () ->
                     Auth.authorize_tool dir ~agent_name:"keeper-analyst-agent"
                       ~token:(Some raw_token) ~tool_name)
              (Ok ()) keeper_strict_auth_regression_tools)
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_authorize_tool_v2_known_keeper_tool_strict_worker_allowed () =
  let result =
    with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
        List.fold_left
          (fun acc tool_name ->
             match acc with
             | Error _ as e -> e
             | Ok () ->
                 Auth.authorize_tool_for_role ~agent_name:"keeper-analyst-agent"
                   ~role:Types.Worker ~tool_name)
          (Ok ()) keeper_strict_auth_regression_tools)
  in
  match result with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

let test_authorize_tool_v2_unknown_keeper_prefix_strict_denied () =
  let result =
    with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
        Auth.authorize_tool_for_role ~agent_name:"keeper-analyst-agent"
          ~role:Types.Worker ~tool_name:"keeper_totally_fake")
  in
  match result with
  | Ok () -> fail "unknown keeper_* prefix should not bypass strict auth"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Printf.sprintf "wrong error: %s" (Types.masc_error_to_string e))

let test_declared_tool_permission_from_tool_spec () =
  let name = "__test_declared_permission_tool" in
  let spec =
    Tool_spec.create
      ~name
      ~description:"declared permission tool"
      ~module_tag:Tool_dispatch.Mod_misc
      ~input_schema:(`Assoc [ ("type", `String "object") ])
      ~handler_binding:Tag_dispatch
      ~required_permission:Types.CanAdmin
      ()
  in
  Tool_spec.register spec;
  check bool "tool permission comes from Tool_spec metadata" true
    (Auth.permission_for_tool name = Some Types.CanAdmin)

(* ============================================ *)
(* Enable/disable tests                         *)
(* ============================================ *)

let test_enable_disable_auth () =
  let dir = setup_test_room () in
  let initially_disabled = not (Auth.is_auth_enabled dir) in
  let _ = Auth.enable_auth dir ~require_token:false ~agent_name:"test-admin" in
  let enabled = Auth.is_auth_enabled dir in
  Auth.disable_auth dir;
  let disabled_again = not (Auth.is_auth_enabled dir) in
  cleanup_test_room dir;
  check bool "auth disabled initially" true initially_disabled;
  check bool "auth enabled after enable" true enabled;
  check bool "auth disabled after disable" true disabled_again

(* ============================================ *)
(* Test suite                                   *)
(* ============================================ *)

let () =
  Random.init 42;
  run "Auth" [
    "token_generation", [
      test_case "generate token" `Quick test_token_generation;
      test_case "sha256 hash" `Quick test_sha256_hash;
    ];
    "config", [
      test_case "default config" `Quick test_default_auth_config;
      test_case "save/load config" `Quick test_save_load_auth_config;
      test_case "save/load config in Eio runtime" `Quick
        test_save_load_auth_config_in_eio_runtime;
      test_case "auth config saved private" `Quick
        test_auth_config_saved_private;
    ];
    "credentials", [
      test_case "create credential" `Quick test_create_credential;
      test_case "credential saved private" `Quick
        test_credential_saved_private;
      test_case "verify token" `Quick test_verify_token;
      test_case "verify wrong token" `Quick test_verify_wrong_token;
      test_case "verify token reports token owner on agent mismatch" `Quick
        test_verify_token_reports_token_owner_on_agent_mismatch;
      test_case "verify token allows generated alias for owner prefix" `Quick
        test_verify_token_allows_generated_alias_for_token_owner_prefix;
      test_case "resolve agent from token" `Quick test_resolve_agent_from_token;
      test_case "list credentials" `Quick test_list_credentials;
      test_case "delete credential" `Quick test_delete_credential;
      test_case "load_credential redirect stub resolves" `Quick
        test_load_credential_redirect_stub;
      test_case "delete uuid-backed credential removes target" `Quick
        test_delete_uuid_backed_credential_removes_redirect_target;
      test_case "load_credential exact match wins over fallback" `Quick
        test_load_credential_exact_wins_over_fallback;
      test_case "extract_agent_type_prefix keeper aliases" `Quick
        test_extract_agent_type_prefix_keeper_aliases;
      test_case "verify_token keeper exact match" `Quick
        test_verify_token_keeper_exact_match;
      test_case "verify_token keeper alias archives dual-identity bare" `Quick
        test_verify_token_keeper_alias_archives_dual_identity_bare;
      test_case "load_credential missing keeper alias stays quiet" `Quick
        test_load_credential_missing_keeper_alias_stays_quiet;
      test_case "verify_token dashboard legacy alias fallback" `Quick
        test_verify_token_dashboard_legacy_alias_fallback;
      test_case "save_raw_token_credential uses provided token" `Quick
        test_save_raw_token_credential_uses_provided_token;
      test_case "ensure_keeper_credential uses per-keeper token" `Quick
        test_ensure_keeper_credential_uses_per_keeper_token;
      test_case "ensure_keeper_credential reuses uuid" `Quick
        test_ensure_keeper_credential_reuses_uuid;
      test_case "ensure_keeper_credential archives dual-identity bare" `Quick
        test_ensure_keeper_credential_archives_dual_identity_bare;
      test_case "ensure_keeper_credential no archive on clean state" `Quick
        test_ensure_keeper_credential_no_archive_when_no_bare;
    ];
    "permissions", [
      test_case "worker permissions" `Quick test_worker_permissions;
      test_case "admin permissions" `Quick test_admin_permissions;
    ];
    "authorization", [
      test_case "auth disabled allows all" `Quick test_auth_disabled_allows_all;
      test_case "auth enabled requires token" `Quick test_auth_enabled_requires_token;
      test_case "auth enabled with valid token" `Quick test_auth_enabled_with_valid_token;
      test_case "permission denied for worker admin action" `Quick
        test_permission_denied_for_worker_admin_action;
      test_case "strict unknown masc tool allows worker"
        `Quick test_authorize_unknown_masc_tool_strict_worker_allowed;
      test_case "strict unknown non-masc tool denied"
        `Quick test_authorize_unknown_non_masc_tool_strict_denied;
      test_case "strict unknown canonical tool allows worker"
        `Quick test_authorize_unknown_canonical_tool_strict_worker_allowed;
      test_case "strict known keeper tool allows worker"
        `Quick test_authorize_known_keeper_tool_strict_worker_allowed;
      test_case "strict v2 known keeper tool allows worker"
        `Quick test_authorize_tool_v2_known_keeper_tool_strict_worker_allowed;
      test_case "strict v2 fake keeper prefix denied"
        `Quick test_authorize_tool_v2_unknown_keeper_prefix_strict_denied;
      test_case "declared tool permission from Tool_spec"
        `Quick test_declared_tool_permission_from_tool_spec;
    ];
    "enable_disable", [
      test_case "enable/disable auth" `Quick test_enable_disable_auth;
      test_case "room secret saved private" `Quick test_room_secret_saved_private;
    ];
  ]
