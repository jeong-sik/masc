module Env_keeper_scrub = Masc.Env_keeper_scrub

let allowed_basic_envs () =
  let must_allow =
    [ "PATH"; "HOME"; "TMPDIR"; "LANG"; "LC_ALL"; "LC_CTYPE"
    ; "USER"; "LOGNAME"; "SHELL"
    ; "TERM"; "EDITOR"; "VISUAL"; "PAGER"
    ; "XDG_CONFIG_HOME"; "XDG_CACHE_HOME"; "XDG_DATA_HOME"
    ; "HTTP_PROXY"; "HTTPS_PROXY"; "NO_PROXY"; "SSL_CERT_FILE"
    ; "GIT_AUTHOR_NAME"; "GIT_AUTHOR_EMAIL"
    ; "GIT_COMMITTER_NAME"; "GIT_COMMITTER_EMAIL"
    ; "MASC_BASE_PATH"; "MASC_CONFIG_DIR"
    ]
  in
  List.iter
    (fun key ->
       Alcotest.(check bool) (Printf.sprintf "%s is allowed" key) true
         (Env_keeper_scrub.is_keeper_process_allowed key))
    must_allow
;;

let denied_secret_suffixes () =
  let must_deny =
    [ "ANTHROPIC_API_KEY"; "OPENAI_API_KEY"; "GEMINI_API_KEY"
    ; "AWS_ACCESS_KEY_ID"; "AWS_SECRET_ACCESS_KEY"
    ; "MY_CUSTOM_SECRET"; "FOO_PASSWORD"; "BAR_CREDENTIALS"
    ; "MASC_ADMIN_TOKEN"; "MASC_INTERNAL_MCP_TOKEN"
      (* Operator ambient GitHub tokens must never cross into a keeper; the
         [_TOKEN] deny suffix enforces this. The keeper's own token is supplied
         out-of-band by [Keeper_secret_projection], not via this allowlist.
         See RFC-0236 §6 / RFC-0007. *)
    ; "GITHUB_TOKEN"; "GH_TOKEN"
    ]
  in
  List.iter
    (fun key ->
       Alcotest.(check bool) (Printf.sprintf "%s is denied" key) false
         (Env_keeper_scrub.is_keeper_process_allowed key))
    must_deny
;;

let denied_masc_admin_prefix () =
  Alcotest.(check bool) "MASC_ADMIN_TOKEN denied" false
    (Env_keeper_scrub.is_keeper_process_allowed "MASC_ADMIN_TOKEN");
  Alcotest.(check bool) "MASC_INTERNAL_MCP_TOKEN denied" false
    (Env_keeper_scrub.is_keeper_process_allowed "MASC_INTERNAL_MCP_TOKEN");
  Alcotest.(check bool) "MASC_SECRET_DIR denied" false
    (Env_keeper_scrub.is_keeper_process_allowed "MASC_SECRET_DIR")
;;

let docker_control_plane_is_separate () =
  List.iter
    (fun key ->
       Alcotest.(check bool) (key ^ " denied to Keeper") false
         (Env_keeper_scrub.is_keeper_process_allowed key);
       Alcotest.(check bool) (key ^ " allowed to Docker control plane") true
         (Env_keeper_scrub.is_control_plane_allowed key))
    [ "DOCKER_HOST"; "DOCKER_TLS_VERIFY"; "DOCKER_CERT_PATH"
    ; "MASC_KEEPER_TEST_DOCKER_LOG"
    ];
  List.iter
    (fun key ->
       Alcotest.(check bool) (key ^ " runtime prefix is not re-exported") false
         (Env_keeper_scrub.is_keeper_process_allowed key))
    [ "MASC_KEEPER_BOOTSTRAP_ENABLED"; "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" ]
;;

let filter_environment_keeps_only_allowed () =
  let input =
    [| "ANTHROPIC_API_KEY=sk-ant-secret"
     ; "MASC_ADMIN_TOKEN=admin-secret"
     ; "PATH=/usr/bin:/bin"
     ; "HOME=/tmp"
     ; "MASC_BASE_PATH=/app"
     ; "GIT_AUTHOR_NAME=keeper"
    |]
  in
  let filtered = Env_keeper_scrub.filter_keeper_environment input in
  let keys =
    Array.to_list filtered
    |> List.map (fun entry ->
      match String.index_opt entry '=' with
      | None -> entry
      | Some i -> String.sub entry 0 i)
  in
  Alcotest.(check bool) "ANTHROPIC_API_KEY stripped" false
    (List.mem "ANTHROPIC_API_KEY" keys);
  Alcotest.(check bool) "MASC_ADMIN_TOKEN stripped" false
    (List.mem "MASC_ADMIN_TOKEN" keys);
  Alcotest.(check bool) "PATH preserved" true (List.mem "PATH" keys);
  Alcotest.(check bool) "HOME preserved" true (List.mem "HOME" keys);
  Alcotest.(check bool) "MASC_BASE_PATH preserved" true
    (List.mem "MASC_BASE_PATH" keys);
  Alcotest.(check bool) "GIT_AUTHOR_NAME preserved" true
    (List.mem "GIT_AUTHOR_NAME" keys)
;;

let filter_environment_drops_entries_without_equals () =
  let input = [| "WEIRD_NO_EQUALS"; "ANTHROPIC_API_KEY=secret" |] in
  let filtered = Env_keeper_scrub.filter_keeper_environment input in
  let has_weird =
    Array.to_list filtered |> List.exists (fun e -> e = "WEIRD_NO_EQUALS")
  in
  let has_anthropic =
    Array.to_list filtered |> List.exists (fun e -> e = "ANTHROPIC_API_KEY=secret")
  in
  Alcotest.(check bool) "WEIRD_NO_EQUALS dropped (not allowed)" false has_weird;
  Alcotest.(check bool) "ANTHROPIC_API_KEY stripped" false has_anthropic
;;

let removed_extra_allow_env_cannot_open_credential_boundary () =
  let prior = Sys.getenv_opt "MASC_KEEPER_ALLOW_EXTRA" in
  Unix.putenv "MASC_KEEPER_ALLOW_EXTRA" "AWS_ACCESS_KEY_ID,CUSTOM_OK";
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv "MASC_KEEPER_ALLOW_EXTRA" value
      | None -> Unix.putenv "MASC_KEEPER_ALLOW_EXTRA" "")
    (fun () ->
       Alcotest.(check bool) "ambient access-key id stays denied" false
         (Env_keeper_scrub.is_keeper_process_allowed "AWS_ACCESS_KEY_ID");
       Alcotest.(check bool) "arbitrary ambient key stays denied" false
         (Env_keeper_scrub.is_keeper_process_allowed "CUSTOM_OK"))
;;

let mem entry env = Array.to_list env |> List.exists (fun e -> e = entry)

(* A non-C host locale would localise strerror and silently break the
   EINTR retry marker; filter_environment_c_messages must pin messages to
   C while leaving character encoding to the host. *)
let c_messages_pins_message_locale () =
  let input =
    [| "PATH=/usr/bin"
     ; "LC_ALL=ko_KR.UTF-8"
     ; "LC_MESSAGES=fr_FR.UTF-8"
     ; "LANG=ko_KR.UTF-8"
     ; "LC_CTYPE=ko_KR.UTF-8"
    |]
  in
  let out =
    Env_keeper_scrub.filter_control_plane_environment_c_messages input
  in
  Alcotest.(check bool) "LC_MESSAGES pinned to C" true (mem "LC_MESSAGES=C" out);
  Alcotest.(check bool) "LC_ALL neutralised to empty" true (mem "LC_ALL=" out);
  Alcotest.(check bool) "host LC_ALL value dropped" false
    (mem "LC_ALL=ko_KR.UTF-8" out);
  Alcotest.(check bool) "host LC_MESSAGES value dropped" false
    (mem "LC_MESSAGES=fr_FR.UTF-8" out);
  (* encoding categories are left to the host so UTF-8 output survives *)
  Alcotest.(check bool) "LANG retained" true (mem "LANG=ko_KR.UTF-8" out);
  Alcotest.(check bool) "LC_CTYPE retained" true (mem "LC_CTYPE=ko_KR.UTF-8" out)
;;

let c_messages_pins_even_without_host_locale () =
  let out =
    Env_keeper_scrub.filter_control_plane_environment_c_messages
      [| "PATH=/usr/bin" |]
  in
  Alcotest.(check bool) "LC_MESSAGES=C appended" true (mem "LC_MESSAGES=C" out);
  Alcotest.(check bool) "LC_ALL= appended" true (mem "LC_ALL=" out)
;;

let filter_environment_scrubs_proxy_credentials () =
  let input =
    [| "PATH=/usr/bin"
     ; "HTTP_PROXY=https://operator:secret@proxy.example.com:8080"
     ; "HTTPS_PROXY=https://user:pass@proxy.internal/path"
     ; "NO_PROXY=localhost,.example.com"
    |]
  in
  let out = Env_keeper_scrub.filter_keeper_environment input in
  Alcotest.(check bool) "HTTP_PROXY value redacted" true
    (mem "HTTP_PROXY=https://[REDACTED]@proxy.example.com:8080" out);
  Alcotest.(check bool) "HTTPS_PROXY value redacted" true
    (mem "HTTPS_PROXY=https://[REDACTED]@proxy.internal/path" out);
  Alcotest.(check bool) "NO_PROXY preserved" true
    (mem "NO_PROXY=localhost,.example.com" out);
  Alcotest.(check bool) "raw proxy password stripped" false
    (Array.to_list out |> List.exists (fun e ->
       String_util.contains_substring e "secret"
       || String_util.contains_substring e "pass"))
;;

let () =
  Alcotest.run
    "env keeper scrub"
    [ ( "allowlist"
      , [ Alcotest.test_case "basic envs are allowed" `Quick allowed_basic_envs
        ; Alcotest.test_case "secret suffixes are denied" `Quick
            denied_secret_suffixes
        ; Alcotest.test_case "MASC_ADMIN_ prefix is denied" `Quick
            denied_masc_admin_prefix
        ; Alcotest.test_case "Docker control plane is separate" `Quick
            docker_control_plane_is_separate
        ; Alcotest.test_case "removed extra allow cannot open credentials" `Quick
            removed_extra_allow_env_cannot_open_credential_boundary
        ] )
    ; ( "filter_environment"
      , [ Alcotest.test_case "keeps allowed keys only" `Quick
            filter_environment_keeps_only_allowed
        ; Alcotest.test_case "drops unknown keys without equals" `Quick
            filter_environment_drops_entries_without_equals
        ; Alcotest.test_case "scrubs proxy URL credentials" `Quick
            filter_environment_scrubs_proxy_credentials
        ] )
    ; ( "c_messages_locale"
      , [ Alcotest.test_case "pins message locale to C" `Quick
            c_messages_pins_message_locale
        ; Alcotest.test_case "pins even without host locale" `Quick
            c_messages_pins_even_without_host_locale
        ] )
    ]
;;
