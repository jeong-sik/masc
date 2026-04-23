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
  let _ = Auth.create_token dir ~agent_name:"codex" ~role:Types.Reader in
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

let test_load_credential_nickname_fallback () =
  (* Exact-name misses fall through to the agent-type prefix so a single
     credential (e.g. "adversary.json") covers dynamically generated
     nicknames ("adversary-fair-tapir"). *)
  let dir = setup_test_room () in
  let _ = Auth.create_token dir ~agent_name:"adversary" ~role:Types.Worker in
  let hit = Auth.load_credential dir "adversary-fair-tapir" in
  let miss_non_nickname = Auth.load_credential dir "unknown_plain" in
  let miss_different_family = Auth.load_credential dir "stranger-fair-tapir" in
  cleanup_test_room dir;
  (match hit with
   | Some cred when cred.agent_name = "adversary" -> ()
   | _ -> fail "nickname 'adversary-fair-tapir' should resolve via prefix");
  (match miss_non_nickname with
   | None -> ()
   | Some _ -> fail "plain unknown names must not fall through");
  (match miss_different_family with
   | None -> ()
   | Some _ -> fail "unrelated agent_type must not reuse another keeper's cred")

let test_load_credential_exact_wins_over_fallback () =
  (* If both the nickname file and the prefix file exist, the exact
     match wins so a per-nickname override remains possible. *)
  let dir = setup_test_room () in
  let _ = Auth.create_token dir ~agent_name:"adversary" ~role:Types.Worker in
  let _ = Auth.create_token dir ~agent_name:"adversary-fair-tapir" ~role:Types.Reader in
  let resolved = Auth.load_credential dir "adversary-fair-tapir" in
  cleanup_test_room dir;
  match resolved with
  | Some cred when cred.agent_name = "adversary-fair-tapir" && cred.role = Types.Reader -> ()
  | Some cred ->
      fail (Printf.sprintf "unexpected resolution: %s/%s" cred.agent_name
              (match cred.role with Types.Reader -> "Reader" | Worker -> "Worker"
               | Admin -> "Admin"))
  | None -> fail "exact match should resolve"

let test_extract_agent_type_prefix_keeper_aliases () =
  check (option string) "keeper simple alias" (Some "sangsu")
    (Auth.extract_agent_type_prefix "keeper-sangsu-agent");
  check (option string) "keeper hyphenated alias" (Some "masc-improver")
    (Auth.extract_agent_type_prefix "keeper-masc-improver-agent");
  check (option string) "generated nickname" (Some "adversary")
    (Auth.extract_agent_type_prefix "adversary-fair-tapir");
  check (option string) "plain name stays plain" (Some "sangsu")
    (Auth.extract_agent_type_prefix "sangsu");
  check (option string) "two segment keeper fallback unchanged" (Some "keeper")
    (Auth.extract_agent_type_prefix "keeper-sangsu")

let test_verify_token_keeper_alias_fallback () =
  let dir = setup_test_room () in
  let result =
    match Auth.create_token dir ~agent_name:"sangsu" ~role:Types.Admin with
    | Ok (raw_token, _) ->
        Auth.verify_token dir ~agent_name:"keeper-sangsu-agent" ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok cred -> check string "fallback credential owner" "sangsu" cred.agent_name
  | Error e ->
      fail
        (Printf.sprintf
           "keeper alias should verify via fallback credential: %s"
           (Types.masc_error_to_string e))

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

let test_ensure_keeper_credential_uses_keeper_middle_name () =
  let dir = setup_test_room () in
  let ensure_result =
    with_env "MASC_MCP_TOKEN" "" (fun () ->
      Auth.ensure_keeper_credential dir ~agent_name:"keeper-masc-improver-agent")
  in
  let verify_result =
    match ensure_result with
    | Ok (raw_token, _) ->
        Auth.verify_token dir ~agent_name:"keeper-masc-improver-agent"
          ~token:raw_token
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match ensure_result, verify_result with
  | Ok (_raw_token, cred), Ok alias_cred ->
      check string "stored under keeper middle" "masc-improver" cred.agent_name;
      check string "alias resolves same credential" "masc-improver"
        alias_cred.agent_name
  | Error e, _ | _, Error e ->
      fail
        (Printf.sprintf
           "ensure_keeper_credential should mint a keeper-scoped token: %s"
           (Types.masc_error_to_string e))

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
        Filename.concat (Auth.auth_dir dir) "masc-improver.token"
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
          check string "first credential uses keeper middle name" "masc-improver"
            first_cred.agent_name;
          check string "reused credential keeps keeper middle name" "masc-improver"
            reused_cred.agent_name;
          check string "persisted keeper raw token reused" first_raw_token
            reused_raw_token
      | Error e, _ | _, Error e ->
          fail
            (Printf.sprintf
               "ensure_keeper_credential should reuse persisted keeper token: %s"
               (Types.masc_error_to_string e)))

(* ============================================ *)
(* Permission tests                             *)
(* ============================================ *)

let test_reader_permissions () =
  check bool "reader can read" true
    (Types.has_permission Types.Reader Types.CanReadState);
  check bool "reader cannot claim" false
    (Types.has_permission Types.Reader Types.CanClaimTask);
  check bool "reader cannot init" false
    (Types.has_permission Types.Reader Types.CanInit)

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

let test_permission_denied_for_reader () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"reader_agent" ~role:Types.Reader in
  let check_result = match create_result with
    | Ok (raw_token, _) ->
        Auth.check_permission dir ~agent_name:"reader_agent" ~token:(Some raw_token) ~permission:Types.CanClaimTask
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match check_result with
  | Ok () -> fail "reader should not claim"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Printf.sprintf "wrong error: %s" (Types.masc_error_to_string e))

let test_optional_token_overrides_reader_default_role () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:false ~agent_name:"test-admin" in
  let cfg = Auth.load_auth_config dir in
  Auth.save_auth_config dir { cfg with default_role = Types.Reader };
  let result =
    match Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker with
    | Ok (raw_token, _) ->
        Auth.check_permission dir ~agent_name:"worker_agent"
          ~token:(Some raw_token) ~permission:Types.CanClaimTask
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error e ->
      fail
        (Printf.sprintf
           "optional worker token should override reader default_role: %s"
           (Types.masc_error_to_string e))

let test_optional_token_authorizes_keeper_tool_when_default_role_reader () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:false ~agent_name:"test-admin" in
  let cfg = Auth.load_auth_config dir in
  Auth.save_auth_config dir { cfg with default_role = Types.Reader };
  let result =
    match Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker with
    | Ok (raw_token, _) ->
        Auth.authorize_tool_v2 dir ~agent_name:"worker_agent"
          ~token:(Some raw_token)
          ~tool_name:"masc_keeper_create_from_persona"
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error e ->
      fail
        (Printf.sprintf
           "optional worker token should authorize keeper spawn tool: %s"
           (Types.masc_error_to_string e))

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

let test_authorize_unknown_masc_tool_strict_reader_denied () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"reader_agent" ~role:Types.Reader in
  let result =
    match create_result with
    | Ok (raw_token, _) ->
        with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
            Auth.authorize_tool dir ~agent_name:"reader_agent" ~token:(Some raw_token)
              ~tool_name:"masc_unknown_tool")
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> fail "reader should be denied in strict mode for unknown masc tool"
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Printf.sprintf "wrong error: %s" (Types.masc_error_to_string e))

let test_authorize_unknown_non_masc_tool_strict_denied () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker in
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
  | Error (Types.Forbidden _) -> ()
  | Error e -> fail (Printf.sprintf "wrong error: %s" (Types.masc_error_to_string e))

let test_authorize_unknown_canonical_tool_strict_worker_allowed () =
  let dir = setup_test_room () in
  let _ = Auth.enable_auth dir ~require_token:true ~agent_name:"test-admin" in
  let create_result = Auth.create_token dir ~agent_name:"worker_agent" ~role:Types.Worker in
  let result =
    match create_result with
    | Ok (raw_token, _) ->
        with_env "MASC_TOOL_AUTH_STRICT" "1" (fun () ->
            Auth.authorize_tool dir ~agent_name:"worker_agent" ~token:(Some raw_token)
              ~tool_name:"decision.unlisted_tool")
    | Error e -> Error e
  in
  cleanup_test_room dir;
  match result with
  | Ok () -> ()
  | Error e -> fail (Types.masc_error_to_string e)

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
      test_case "resolve agent from token" `Quick test_resolve_agent_from_token;
      test_case "list credentials" `Quick test_list_credentials;
      test_case "delete credential" `Quick test_delete_credential;
      test_case "load_credential nickname prefix fallback" `Quick
        test_load_credential_nickname_fallback;
      test_case "load_credential exact match wins over fallback" `Quick
        test_load_credential_exact_wins_over_fallback;
      test_case "extract_agent_type_prefix keeper aliases" `Quick
        test_extract_agent_type_prefix_keeper_aliases;
      test_case "verify_token keeper alias fallback" `Quick
        test_verify_token_keeper_alias_fallback;
      test_case "load_credential missing keeper alias stays quiet" `Quick
        test_load_credential_missing_keeper_alias_stays_quiet;
      test_case "verify_token dashboard legacy alias fallback" `Quick
        test_verify_token_dashboard_legacy_alias_fallback;
      test_case "save_raw_token_credential uses provided token" `Quick
        test_save_raw_token_credential_uses_provided_token;
      test_case "ensure_keeper_credential uses keeper middle name" `Quick
        test_ensure_keeper_credential_uses_keeper_middle_name;
      test_case "ensure_keeper_credential reuses persisted raw token on env mismatch" `Quick
        test_ensure_keeper_credential_reuses_persisted_raw_token_when_env_mismatched;
    ];
    "permissions", [
      test_case "reader permissions" `Quick test_reader_permissions;
      test_case "worker permissions" `Quick test_worker_permissions;
      test_case "admin permissions" `Quick test_admin_permissions;
    ];
    "authorization", [
      test_case "auth disabled allows all" `Quick test_auth_disabled_allows_all;
      test_case "auth enabled requires token" `Quick test_auth_enabled_requires_token;
      test_case "auth enabled with valid token" `Quick test_auth_enabled_with_valid_token;
      test_case "permission denied for reader" `Quick test_permission_denied_for_reader;
      test_case "optional token overrides reader default role"
        `Quick test_optional_token_overrides_reader_default_role;
      test_case "optional token authorizes keeper tool"
        `Quick test_optional_token_authorizes_keeper_tool_when_default_role_reader;
      test_case "strict unknown masc tool allows worker"
        `Quick test_authorize_unknown_masc_tool_strict_worker_allowed;
      test_case "strict unknown masc tool denies reader"
        `Quick test_authorize_unknown_masc_tool_strict_reader_denied;
      test_case "strict unknown non-masc tool denied"
        `Quick test_authorize_unknown_non_masc_tool_strict_denied;
      test_case "strict unknown canonical tool allows worker"
        `Quick test_authorize_unknown_canonical_tool_strict_worker_allowed;
      test_case "declared tool permission from Tool_spec"
        `Quick test_declared_tool_permission_from_tool_spec;
    ];
    "enable_disable", [
      test_case "enable/disable auth" `Quick test_enable_disable_auth;
      test_case "room secret saved private" `Quick test_room_secret_saved_private;
    ];
  ]
