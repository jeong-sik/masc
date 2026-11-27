(* Live RBAC E2E fixture seeder.

   Creates four isolated workspaces under [--root <dir>] using the real
   production Auth and Authz modules (no mocked auth state, no masc_test_deps):
   1. [su_off]: single-user workspace with auth disabled.
   2. [su_auth]: single-user workspace with auth enabled (require_token=true)
      and real Admin, Worker, and Player tokens minted via Auth.create_token.
   3. [su_strict]: separate single-user auth-enabled workspace for strict
      loopback (MASC_HTTP_AUTH_STRICT=1) verification.
   4. [ma]: multi-account installation bootstrapped via Authz_bootstrap with
      embedded runtime.toml, two admitted Admins (admin1, admin2), one admitted
      Worker (worker1) with a seeded personal ollama_cloud key account and
      runtime, real browser sessions (__Host-masc_session cookies + CSRF
      tokens), scoped PATs (admin PAT, worker full-personal PAT with
      read_state/invoke_model/use_tool/manage_own_provider/manage_own_keeper,
      worker read-only PAT with read_state only), and a Service credential.

   Writes the fixture manifest to [<root>/manifest.json] with mode 0600 and
   prints only that path on stdout so raw credentials never enter logs. *)

open Authz_types
open Authz_records

let fail msg =
  Printf.eprintf "rbac_live_e2e_seed: %s\n%!" msg;
  exit 1
;;

let ok_or_fail ~ctx ~show = function
  | Ok v -> v
  | Error e -> fail (Printf.sprintf "%s: %s" ctx (show e))
;;

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let write_private_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc content);
  Unix.chmod path 0o600
;;

let ensure_dir path =
  Fs_compat.mkdir_p path;
  Unix.chmod path 0o700
;;

let place_runtime_toml ~base_path =
  let path = Server_runtime_setup_actions.config_path ~base_path in
  match Server_runtime_config_root_bootstrap.place_embedded_runtime_toml ~path with
  | Ok Server_runtime_config_root_bootstrap.Embedded_written
  | Ok Server_runtime_config_root_bootstrap.Existing_kept -> ()
  | Error (Server_runtime_config_root_bootstrap.Not_published detail)
  | Error (Server_runtime_config_root_bootstrap.Not_synced detail) ->
    fail (Printf.sprintf "place runtime.toml at %s: %s" path detail)
;;

let seed_su_off ~root =
  let base = Filename.concat root "su_off" in
  ensure_dir base;
  Auth.disable_auth base;
  place_runtime_toml ~base_path:base;
  `Assoc [ "base_path", `String base ]
;;

let seed_su_auth ~root ~dir_name =
  let base = Filename.concat root dir_name in
  ensure_dir base;
  let (_workspace_secret, bootstrap_token) =
    Auth.enable_auth base ~require_token:true ~agent_name:"su-admin"
  in
  let admin_token, (_ : Masc_domain.agent_credential), (_ : Auth.startup_admin_token_source) =
    let seed_tok =
      match bootstrap_token with
      | Some tok -> tok
      | None -> Auth.generate_token ()
    in
    ok_or_fail
      ~ctx:"prepare startup admin token"
      ~show:Masc_domain.masc_error_to_string
      (Auth.prepare_startup_admin_token base ~raw_token:(Some seed_tok))
  in
  let worker_token, (_ : Masc_domain.agent_credential) =
    ok_or_fail
      ~ctx:"create su-worker token"
      ~show:Masc_domain.masc_error_to_string
      (Auth.create_token base ~agent_name:"su-worker" ~role:Masc_domain.Worker)
  in
  let player_token, (_ : Masc_domain.agent_credential) =
    ok_or_fail
      ~ctx:"create su-player token"
      ~show:Masc_domain.masc_error_to_string
      (Auth.create_token base ~agent_name:"su-player" ~role:Masc_domain.Player)
  in
  place_runtime_toml ~base_path:base;
  `Assoc
    [ "base_path", `String base
    ; "tokens",
      `Assoc
        [ "admin", `String admin_token
        ; "worker", `String worker_token
        ; "player", `String player_token
        ]
    ]
;;

let drawing values =
  let left = ref values in
  let fresh = ref 0 in
  fun () ->
    match !left with
    | v :: rest ->
      left := rest;
      v
    | [] ->
      incr fresh;
      Printf.sprintf "%032x" !fresh
;;

let commit_record ~ctx zone ~author ~kind body =
  let (_ : Authz_zone.committed) =
    ok_or_fail
      ~ctx
      ~show:Authz_zone.error_detail
      (Authz_zone.commit zone { Authz_zone.author; kind; body })
  in
  ()
;;

let admit_via_invite zone ~author ~invite_id ~invite_token ~role ~user_draw ~sub =
  let invite_id =
    ok_or_fail ~ctx:"invite_id" ~show:Authz_id.error_to_string (Invite_id.of_string invite_id)
  in
  let digest = Authz_invite_event.Token_digest.of_token invite_token in
  let invite_body =
    ok_or_fail
      ~ctx:"invite body"
      ~show:Authz_body.error_to_string
      (Authz_invite_event.to_body
         (Authz_invite_event.Issued
            { invite_id
            ; token_digest = digest
            ; expires_at_ms = now_ms () + 3_600_000
            ; role
            }))
  in
  commit_record ~ctx:("commit invite " ^ sub) zone ~author ~kind:Authz_record.Kind.Invite invite_body;
  let identity =
    ok_or_fail
      ~ctx:("google identity " ^ sub)
      ~show:Authz_external_identity.error_to_string
      (Authz_external_identity.google ~sub)
  in
  match
    Authz_login.sign_in zone ~now_ms ~draw:(drawing user_draw) ~identity ~invite:(Some digest)
  with
  | Ok (Authz_login.Admitted { user_id; role = _; previously_deleted = _ }) -> user_id
  | Ok (Authz_login.Signed_in _) -> fail ("unexpected Signed_in instead of Admitted for " ^ sub)
  | Error refusal ->
    fail (Printf.sprintf "admit %s failed: %s" sub (Authz_login.refusal_to_string refusal))
;;

let issue_session zone ~user_id ~session_id =
  let cookie =
    ok_or_fail
      ~ctx:("issue session " ^ session_id)
      ~show:Authz_browser_session.error_to_string
      (Authz_browser_session.issue zone ~user_id ~draw:(drawing [ session_id ]) ~replaces:None)
  in
  `Assoc
    [ "user_id", `String (User_id.to_string user_id)
    ; "session_id", `String session_id
    ; "cookie_name", `String Authz_browser_request.session_cookie
    ; "cookie_value", `String (Authz_browser_session.Cookie.to_value cookie)
    ; "csrf_token", `String (Authz_browser_session.csrf_token cookie)
    ]
;;

let issue_pat zone ~user_id ~pat_id ~effects =
  let scope =
    { Authorization_scope.runtimes = Runtime_scope.all
    ; channels = Channel_scope.only (Channel.Set.of_list [ Channel.Direct ])
    ; allowed_effects = Effect_scope.only (Effect.Set.of_list effects)
    }
  in
  let token =
    ok_or_fail
      ~ctx:("issue pat " ^ pat_id)
      ~show:Authz_pat.error_to_string
      (Authz_pat.issue zone ~user_id ~draw:(drawing [ pat_id ]) ~scope ~expires_at_ms:None)
  in
  Authz_credential_token.Pat.to_string token
;;

let seed_ma ~root =
  let ma_root = Filename.concat root "ma" in
  let base = Filename.concat ma_root "base" in
  let xdg = Filename.concat ma_root "xdg" in
  let home = Filename.concat ma_root "home" in
  let config = Filename.concat xdg "masc" in
  let store = Filename.concat (Filename.concat ma_root "store") "external.jsonl" in
  ensure_dir ma_root;
  ensure_dir base;
  ensure_dir xdg;
  ensure_dir home;
  ensure_dir config;
  let workspace_id =
    ok_or_fail ~ctx:"workspace_id" ~show:Authz_id.error_to_string (Workspace_id.of_string "workspace-rbac-e2e")
  in
  let (_ : Authz_bootstrap.completed) =
    ok_or_fail
      ~ctx:"fresh_bootstrap"
      ~show:Authz_bootstrap.error_to_string
      (Authz_bootstrap.fresh_bootstrap
         { Authz_bootstrap.base_path = base
         ; config_dir = Some config
         ; external_store = store
         ; workspace_id
         ; now_ms
         })
  in
  place_runtime_toml ~base_path:base;
  let ma_auth_config = {|{"enabled":true,"require_token":true,"account_mode":"Multi_account"}|} in
  write_private_file (Auth.auth_config_file base) ma_auth_config;
  let log_path = Authz_log.path_of_base_path ~base_path:base in
  let zone =
    ok_or_fail
      ~ctx:"open_at_start"
      ~show:Authz_zone.open_error_to_string
      (Authz_zone.open_at_start ~now_ms ~log_path ~store_path:store)
  in
  let admin1 =
    admit_via_invite
      zone
      ~author:Author.Local_operator
      ~invite_id:"inv-admin-1"
      ~invite_token:(String.make 64 'a')
      ~role:Authz_invite_event.Admin
      ~user_draw:[ "usr-e2e-admin-1"; "ns-e2e-admin-1" ]
      ~sub:"google-e2e-admin-1"
  in
  let admin1_author = Author.Authenticated (Principal.Human admin1) in
  let admin2 =
    admit_via_invite
      zone
      ~author:admin1_author
      ~invite_id:"inv-admin-2"
      ~invite_token:(String.make 64 'b')
      ~role:Authz_invite_event.Admin
      ~user_draw:[ "usr-e2e-admin-2"; "ns-e2e-admin-2" ]
      ~sub:"google-e2e-admin-2"
  in
  let worker1 =
    admit_via_invite
      zone
      ~author:admin1_author
      ~invite_id:"inv-worker-1"
      ~invite_token:(String.make 64 'c')
      ~role:Authz_invite_event.Member
      ~user_draw:[ "usr-e2e-worker-1"; "ns-e2e-worker-1" ]
      ~sub:"google-e2e-worker-1"
  in
  let admin1_session = issue_session zone ~user_id:admin1 ~session_id:"sess-e2e-admin-1" in
  let admin2_session = issue_session zone ~user_id:admin2 ~session_id:"sess-e2e-admin-2" in
  let worker1_session = issue_session zone ~user_id:worker1 ~session_id:"sess-e2e-worker-1" in
  let admin1_pat =
    issue_pat
      zone
      ~user_id:admin1
      ~pat_id:"pat-e2e-admin-1"
      ~effects:
        [ Effect.Read_state
        ; Effect.Invoke_model
        ; Effect.Use_tool
        ; Effect.Manage_own_provider
        ; Effect.Manage_own_keeper
        ; Effect.Read_audit_metadata
        ]
  in
  let worker_pat_provider =
    issue_pat
      zone
      ~user_id:worker1
      ~pat_id:"pat-e2e-worker-provider"
      ~effects:
        [ Effect.Read_state
        ; Effect.Invoke_model
        ; Effect.Use_tool
        ; Effect.Manage_own_provider
        ; Effect.Manage_own_keeper
        ]
  in
  let worker_pat_readonly =
    issue_pat
      zone
      ~user_id:worker1
      ~pat_id:"pat-e2e-worker-readonly"
      ~effects:[ Effect.Read_state ]
  in
  let worker_provider_account_id = "pa-e2e-worker-1" in
  let worker_integration_id = "ollama_cloud" in
  let worker_runtime_id = worker_provider_account_id ^ ".ollama-cloud-glm-5-3-flash" in
  let pa_id =
    ok_or_fail
      ~ctx:"provider_account_id"
      ~show:Authz_id.error_to_string
      (Provider_account_id.of_string worker_provider_account_id)
  in
  let integ_id =
    ok_or_fail
      ~ctx:"integration_id"
      ~show:Authz_id.error_to_string
      (Integration_id.of_string worker_integration_id)
  in
  ok_or_fail
    ~ctx:"link worker1 provider account"
    ~show:Authz_provider_account.error_to_string
    (Authz_provider_account.link_key zone ~user_id:worker1 ~provider_account_id:pa_id ~integration_id:integ_id);
  let worker1_ns =
    ok_or_fail
      ~ctx:"worker1 namespace"
      ~show:Authz_id.error_to_string
      (Account_home_namespace.of_string "ns-e2e-worker-1")
  in
  let worker1_runtime_root =
    Runtime_account_home_layout.person_runtime_root ~base_path:base ~namespace:worker1_ns
  in
  let accounts_root = Filename.dirname worker1_runtime_root in
  ensure_dir (Filename.dirname accounts_root);
  ensure_dir accounts_root;
  ensure_dir worker1_runtime_root;
  let worker1_key =
    match Runtime_api_key_file.key_of_string "rbac-e2e-seeded-ollama-key-0001" with
    | Some k -> k
    | None -> fail "seeded worker1 key was rejected"
  in
  ok_or_fail
    ~ctx:"write worker1 key account files"
    ~show:Runtime_key_account_files.make_error_detail
    (Runtime_key_account_files.make_for
       ~home:Runtime_key_account_files.No_home
       ~runtime_root:worker1_runtime_root
       ~account_id:pa_id
       ~generation:Key_generation.first
       worker1_key);
  let rt_id =
    ok_or_fail
      ~ctx:"runtime_id"
      ~show:Authz_id.error_to_string
      (Runtime_id.of_string worker_runtime_id)
  in
  let (_ : Grant_id.t) =
    ok_or_fail
      ~ctx:"make worker1 runtime"
      ~show:Authz_runtime.error_detail
      (Authz_runtime.make
         zone
         ~user_id:worker1
         ~provider_account_id:pa_id
         ~runtime_id:rt_id
         ~self_effects:Effect.(Set.of_list [ Read_state; Invoke_model; Use_tool ])
         ~draw:(drawing [ "grant-e2e-worker-1" ]))
  in
  let service_id =
    ok_or_fail ~ctx:"service_id" ~show:Authz_id.error_to_string (Service_id.of_string "svc-rbac-e2e")
  in
  let service_token =
    ok_or_fail
      ~ctx:"issue service credential"
      ~show:Authz_service_credential.error_to_string
      (Authz_service_credential.issue zone ~service_id ~draw:(drawing [ "sc-e2e-1" ]))
    |> Authz_credential_token.Service_credential.to_string
  in
  `Assoc
    [ "base_path", `String base
    ; "xdg_config_home", `String xdg
    ; "home", `String home
    ; "config_dir", `String config
    ; "external_store", `String store
    ; "worker_provider_account_id", `String worker_provider_account_id
    ; "worker_runtime_id", `String worker_runtime_id
    ; "sessions",
      `Assoc
        [ "admin1", admin1_session
        ; "admin2", admin2_session
        ; "worker1", worker1_session
        ]
    ; "pats",
      `Assoc
        [ "admin1", `String admin1_pat
        ; "worker_provider", `String worker_pat_provider
        ; "worker_readonly", `String worker_pat_readonly
        ]
    ; "service_token", `String service_token
    ]
;;

let parse_root argv =
  match Array.to_list argv with
  | [ _prog; "--root"; dir ] when String.trim dir <> "" -> dir
  | _ -> fail "usage: rbac_live_e2e_seed --root <temp-dir>"
;;

let () =
  let raw_root = parse_root Sys.argv in
  ensure_dir raw_root;
  let root = Unix.realpath raw_root in
  Crypto_rng.ensure_default ();
  Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let manifest =
      `Assoc
        [ "schema", `String "masc.rbac_live_e2e_seed.v1"
        ; "root", `String root
        ; "su_off", seed_su_off ~root
        ; "su_auth", seed_su_auth ~root ~dir_name:"su_auth"
        ; "su_strict", seed_su_auth ~root ~dir_name:"su_strict"
        ; "ma", seed_ma ~root
        ]
    in
    let manifest_path = Filename.concat root "manifest.json" in
    write_private_file manifest_path (Yojson.Safe.pretty_to_string manifest ^ "\n");
    Printf.printf "%s\n%!" manifest_path)
;;
