open Alcotest
open Masc

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let write_executable prefix body =
  let path = Filename.temp_file prefix ".sh" in
  let output = open_out_bin path in
  output_string output body;
  close_out output;
  Unix.chmod path 0o700;
  path
;;

let codex_fixture () =
  let initialize =
    {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
  in
  let account =
    {|{"id":2,"result":{"account":{"type":"chatgpt","email":"not-projected@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
  in
  write_executable
    "masc-dashboard-codex-probe-"
    ("#!/bin/sh\nset -eu\n"
     ^ "IFS= read -r initialize\n"
     ^ "printf '%s\\n' "
     ^ shell_quote initialize
     ^ "\nIFS= read -r initialized\nIFS= read -r account\n"
     ^ "printf '%s\\n' "
     ^ shell_quote account
     ^ "\nwhile IFS= read -r ignored; do :; done\n")
;;

let claude_fixture () =
  let auth =
    {|{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"team","apiProvider":"firstParty"}|}
  in
  write_executable
    "masc-dashboard-claude-probe-"
    ("#!/bin/sh\nset -eu\n"
     ^ "[ \"${1-}\" = auth ] || exit 91\n"
     ^ "printf '%s\\n' "
     ^ shell_quote auth
     ^ "\n")
;;

let runtime_toml ~codex_cli ~claude_cli =
  Printf.sprintf
    "[providers.codex]\n\
     protocol = \"codex-app-server\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [providers.claude]\n\
     protocol = \"claude-code\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [providers.missing]\n\
     protocol = \"claude-code\"\n\
     command = \"/definitely/missing/claude\"\n\
     is-non-interactive = true\n\
     \n\
     [models.codex]\n\
     api-name = \"gpt-fixture\"\n\
     max-context = 128000\n\
     \n\
     [models.claude]\n\
     api-name = \"claude-fixture\"\n\
     max-context = 200000\n\
     \n\
     [models.missing]\n\
     api-name = \"claude-missing\"\n\
     max-context = 200000\n\
     \n\
     [codex.codex]\n\
     [claude.claude]\n\
     [missing.missing]\n\
     \n\
     [runtime]\n\
     default = \"codex.codex\"\n"
    codex_cli
    claude_cli
;;

let json_string path json =
  List.fold_left (fun current field -> Yojson.Safe.Util.member field current) json path
  |> Yojson.Safe.Util.to_string
;;

let json_bool path json =
  List.fold_left (fun current field -> Yojson.Safe.Util.member field current) json path
  |> Yojson.Safe.Util.to_bool
;;

let probe runtime_id =
  match
    Server_dashboard_official_client_probe.probe_body
      ~base_path:"/tmp"
      ~body:(Printf.sprintf {|{"runtime_id":%S}|} runtime_id)
  with
  | Ok json -> json
  | Error error -> fail error.message
;;

let with_probe_runtime f =
  let codex_cli = codex_fixture () in
  let claude_cli = claude_fixture () in
  let config_path = Filename.temp_file "masc-dashboard-official-probe-" ".toml" in
  let output = open_out_bin config_path in
  output_string output (runtime_toml ~codex_cli ~claude_cli);
  close_out output;
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [ codex_cli; claude_cli; config_path ])
    (fun () ->
      match Runtime.init_default ~config_path with
      | Error detail -> fail detail
      | Ok () ->
        Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
            Eio_context.set_env env;
            Eio_context.with_test_env
              ~net:(Eio.Stdenv.net env)
              ~clock:(Eio.Stdenv.clock env)
              ~mono_clock:(Eio.Stdenv.mono_clock env)
              ~sw
              f)))
;;

let test_codex_and_claude_login_are_measured_separately () =
  with_probe_runtime (fun () ->
    let codex = probe "codex.codex" in
    check string "codex kind" "codex" (json_string [ "client_kind" ] codex);
    check string "codex status" "ready" (json_string [ "login"; "status" ] codex);
    check bool "codex authenticated" true (json_bool [ "login"; "authenticated" ] codex);
    check string
      "codex evidence source"
      "configured_executable_self_report"
      (json_string [ "login"; "evidence_source" ] codex);
    check bool
      "codex identity remains unverified"
      false
      (json_bool [ "login"; "identity_verified" ] codex);
    check string
      "codex plan"
      "pro"
      (json_string [ "login"; "subscription_type" ] codex);
    check string
      "codex user agent"
      "fixture/0.147.0"
      (json_string [ "client"; "user_agent" ] codex);
    check string
      "codex execution remains unknown"
      "not_measured"
      (json_string [ "execution"; "status" ] codex);
    check bool
      "email is redacted"
      false
      (String_util.contains_substring (Yojson.Safe.to_string codex) "example.test");
    let claude = probe "claude.claude" in
    check string
      "claude kind"
      "claude_code"
      (json_string [ "client_kind" ] claude);
    check string
      "claude status"
      "ready"
      (json_string [ "login"; "status" ] claude);
    check bool
      "claude identity remains unverified"
      false
      (json_bool [ "login"; "identity_verified" ] claude);
    check string
      "claude auth"
      "claude.ai"
      (json_string [ "login"; "auth_method" ] claude);
    check string
      "claude plan"
      "team"
      (json_string [ "login"; "subscription_type" ] claude))
;;

let test_request_shape_is_exact () =
  match
    Server_dashboard_official_client_probe.probe_body
      ~base_path:"/tmp"
      ~body:{|{"runtime_id":"codex.codex","extra":true}|}
  with
  | Error { code = "request_fields_invalid"; _ } -> ()
  | Error error -> fail error.message
  | Ok _ -> fail "extra official-client probe fields were admitted"
;;

let test_cli_unavailable_is_measured_login_evidence () =
  with_probe_runtime (fun () ->
    let response = probe "missing.missing" in
    check string
      "login status"
      "cli_unavailable"
      (json_string [ "login"; "status" ] response);
    check bool
      "not authenticated"
      false
      (json_bool [ "login"; "authenticated" ] response);
    check bool
      "missing executable identity remains unverified"
      false
      (json_bool [ "login"; "identity_verified" ] response);
    check string
      "execution remains unknown"
      "not_measured"
      (json_string [ "execution"; "status" ] response))
;;

let () =
  run
    "server_dashboard_official_client_probe"
    [ ( "probe"
      , [ test_case
            "Codex and Claude login evidence"
            `Quick
            test_codex_and_claude_login_are_measured_separately
        ; test_case "request shape is exact" `Quick test_request_shape_is_exact
        ; test_case
            "CLI unavailable is measured"
            `Quick
            test_cli_unavailable_is_measured_login_evidence
        ] )
    ]
;;
