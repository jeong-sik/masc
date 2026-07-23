module Env_keeper_scrub = Masc.Env_keeper_scrub

let allowed_basic_envs () =
  let must_allow =
    [ "PATH"; "HOME"; "TMPDIR"; "LANG"; "LC_ALL"; "LC_CTYPE"
    ; "USER"; "LOGNAME"; "SHELL"
    ; "TERM"; "EDITOR"; "VISUAL"; "PAGER"
    ; "XDG_CONFIG_HOME"; "XDG_CACHE_HOME"; "XDG_DATA_HOME"
    ; "DOCKER_HOST"; "DOCKER_TLS_VERIFY"; "DOCKER_CERT_PATH"
    ; "HTTP_PROXY"; "HTTPS_PROXY"; "NO_PROXY"; "SSL_CERT_FILE"
    ; "MASC_BASE_PATH"; "MASC_CONFIG_DIR"
    ]
  in
  List.iter
    (fun key ->
       Alcotest.(check bool) (Printf.sprintf "%s is allowed" key) true
         (Env_keeper_scrub.is_allowed key))
    must_allow
;;

let unknown_host_keys_are_not_inherited () =
  let must_deny =
    [ "ANTHROPIC_API_KEY"; "OPENAI_API_KEY"; "GEMINI_API_KEY"
    ; "AWS_ACCESS_KEY_ID"; "AWS_SECRET_ACCESS_KEY"
    ; "MY_CUSTOM_SECRET"; "FOO_PASSWORD"; "BAR_CREDENTIALS"
    ; "MASC_ADMIN_TOKEN"; "MASC_INTERNAL_MCP_TOKEN"
    ; "SERVICE_TOKEN"; "SECOND_SERVICE_TOKEN"
    ; "MASC_KEEPER_UNKNOWN_RUNTIME_KNOB"
    ]
  in
  List.iter
    (fun key ->
       Alcotest.(check bool) (Printf.sprintf "%s is denied" key) false
         (Env_keeper_scrub.is_allowed key))
    must_deny
;;

let unknown_masc_keys_are_not_inherited () =
  Alcotest.(check bool) "MASC_ADMIN_TOKEN denied" false
    (Env_keeper_scrub.is_allowed "MASC_ADMIN_TOKEN");
  Alcotest.(check bool) "MASC_INTERNAL_MCP_TOKEN denied" false
    (Env_keeper_scrub.is_allowed "MASC_INTERNAL_MCP_TOKEN")
;;

let filter_environment_keeps_only_allowed () =
  let input =
    [| "ANTHROPIC_API_KEY=sk-ant-secret"
     ; "MASC_ADMIN_TOKEN=admin-secret"
     ; "PATH=/usr/bin:/bin"
     ; "HOME=/tmp"
     ; "MASC_BASE_PATH=/app"
     ; "LANG=C.UTF-8"
    |]
  in
  let filtered = Env_keeper_scrub.filter_environment input in
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
  Alcotest.(check bool) "LANG preserved" true
    (List.mem "LANG" keys)
;;

let filter_environment_drops_entries_without_equals () =
  let input = [| "WEIRD_NO_EQUALS"; "ANTHROPIC_API_KEY=secret" |] in
  let filtered = Env_keeper_scrub.filter_environment input in
  let has_weird =
    Array.to_list filtered |> List.exists (fun e -> e = "WEIRD_NO_EQUALS")
  in
  let has_anthropic =
    Array.to_list filtered |> List.exists (fun e -> e = "ANTHROPIC_API_KEY=secret")
  in
  Alcotest.(check bool) "WEIRD_NO_EQUALS dropped (not allowed)" false has_weird;
  Alcotest.(check bool) "ANTHROPIC_API_KEY stripped" false has_anthropic
;;

let mem entry env = Array.to_list env |> List.exists (fun e -> e = entry)

let filter_environment_preserves_allowed_locale_values () =
  let input =
    [| "LC_ALL=ko_KR.UTF-8"
     ; "LANG=ko_KR.UTF-8"
     ; "LC_CTYPE=ko_KR.UTF-8"
     ; "LC_MESSAGES=fr_FR.UTF-8"
    |]
  in
  let out = Env_keeper_scrub.filter_environment input in
  Alcotest.(check bool) "LC_ALL preserved" true (mem "LC_ALL=ko_KR.UTF-8" out);
  Alcotest.(check bool) "LANG preserved" true (mem "LANG=ko_KR.UTF-8" out);
  Alcotest.(check bool) "LC_CTYPE preserved" true (mem "LC_CTYPE=ko_KR.UTF-8" out);
  Alcotest.(check bool)
    "unlisted LC_MESSAGES is dropped"
    false
    (mem "LC_MESSAGES=fr_FR.UTF-8" out);
  Alcotest.(check bool) "LC_MESSAGES is not pinned" false (mem "LC_MESSAGES=C" out)
;;

let filter_environment_scrubs_proxy_credentials () =
  let input =
    [| "PATH=/usr/bin"
     ; "HTTP_PROXY=https://operator:secret@proxy.example.com:8080"
     ; "HTTPS_PROXY=https://user:pass@proxy.internal/path"
     ; "NO_PROXY=localhost,.example.com"
    |]
  in
  let out = Env_keeper_scrub.filter_environment input in
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
        ; Alcotest.test_case "unknown host keys are not inherited" `Quick
            unknown_host_keys_are_not_inherited
        ; Alcotest.test_case "unknown MASC keys are not inherited" `Quick
            unknown_masc_keys_are_not_inherited
        ] )
    ; ( "filter_environment"
      , [ Alcotest.test_case "keeps allowed keys only" `Quick
            filter_environment_keeps_only_allowed
        ; Alcotest.test_case "drops unknown keys without equals" `Quick
            filter_environment_drops_entries_without_equals
        ; Alcotest.test_case "preserves allowed locale values" `Quick
            filter_environment_preserves_allowed_locale_values
        ; Alcotest.test_case "scrubs proxy URL credentials" `Quick
            filter_environment_scrubs_proxy_credentials
        ] )
    ]
;;
