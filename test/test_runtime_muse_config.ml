open Alcotest

let load_list_text ~config_path =
  Runtime.load_list ~config_path
  |> Result.map_error (Runtime.to_diagnostic_text ~config_path)
;;

let runtime_toml ?credential ?(transport = "command = \"muse\"")
    ?(non_interactive = true) () =
  let credential = Option.value credential ~default:"" in
  Printf.sprintf
    "[providers.muse_cli]\n\
     protocol = \"muse-cli\"\n\
     %s\n\
     is-non-interactive = %b\n\
     %s\n\
     [models.muse-default]\n\
     api-name = \"muse-spark-1.3\"\n\
     max-context = 1048576\n\
     \n\
     [muse_cli.muse-default]\n\
     \n\
     [runtime]\n\
     default = \"muse_cli.muse-default\"\n"
    transport
    non_interactive
    credential
;;

let with_runtime_toml content f =
  let path = Filename.temp_file "masc-muse-config-" ".toml" in
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let without_an_installed_client f =
  let home = Filename.temp_dir "masc-no-client-" "" in
  let restore = List.map (fun name -> name, Sys.getenv_opt name) [ "PATH"; "HOME"; "CODEX_INSTALL_DIR" ] in
  List.iter (fun (name, value) -> Unix.putenv name value)
    [ "PATH", ""; "HOME", home; "CODEX_INSTALL_DIR", "" ];
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun (name, value) -> Unix.putenv name (Option.value value ~default:"")) restore;
      Unix.rmdir home)
    f
;;

let load content =
  without_an_installed_client (fun () ->
    with_runtime_toml content (fun path -> load_list_text ~config_path:path))
;;

let test_materializes_official_client_owner () =
  match load (runtime_toml ()) with
  | Error diagnostic -> fail ("muse-cli did not load: " ^ diagnostic)
  | Ok (runtimes, default, _, _, _) ->
    check int "one runtime" 1 (List.length runtimes);
    check string "default" "muse_cli.muse-default" default.id;
    (match default.execution with
     | Runtime_execution.Muse_cli config ->
       check string "CLI, as configured when no client is installed" "muse" config.cli_path;
       check (option string) "model" (Some "muse-spark-1.3") config.model;
       check (float 0.001) "timeout" 300.0 config.timeout_s
     | Runtime_execution.Agent_core _
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Claude_code _
     | Runtime_execution.Antigravity_cli _ ->
       fail "muse-cli was materialized as the wrong execution owner")
;;

let test_declared_credentials_are_rejected () =
  let credential = "[providers.muse_cli.credentials]\ntype = \"env\"\nkey = \"META_API_KEY\"\n" in
  (match load (runtime_toml ~credential ()) with
   | Ok _ -> fail "muse-cli admitted a declared credential"
   | Error _ -> ())
;;

let test_http_transport_is_rejected () =
  (match load (runtime_toml ~transport:"endpoint = \"https://api.meta.ai/v1\"" ()) with
   | Ok _ -> fail "muse-cli admitted an HTTP endpoint"
   | Error _ -> ())
;;

let test_interactive_provider_is_rejected () =
  (match load (runtime_toml ~non_interactive:false ()) with
   | Ok _ -> fail "muse-cli admitted an interactive provider declaration"
   | Error _ -> ())
;;

let test_protocol_name_is_exact () =
  match Runtime_toml.api_format_of_protocol "muse_cli" with
  | Error _ -> ()
  | Ok _ -> fail "underscore protocol alias was silently accepted"
;;

let () =
  run
    "runtime_muse_config"
    [ ( "typed config"
      , [ test_case
            "materializes official-client owner"
            `Quick
            test_materializes_official_client_owner
        ; test_case
            "declared credentials rejected"
            `Quick
            test_declared_credentials_are_rejected
        ; test_case "HTTP transport rejected" `Quick test_http_transport_is_rejected
        ; test_case
            "interactive provider rejected"
            `Quick
            test_interactive_provider_is_rejected
        ; test_case "protocol name exact" `Quick test_protocol_name_is_exact
        ] )
    ]
;;
