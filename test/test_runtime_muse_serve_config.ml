open Alcotest

(* The [muse-serve] protocol in runtime.toml: what a declaration becomes, and
   which declarations are refused. Assertions on refusals read the error's
   path, not its wording. *)

let runtime_id = "muse_code.muse-spark"

let runtime_toml
      ?(protocol = "muse-serve")
      ?(transport = "command = \"muse\"")
      ?(non_interactive = true)
      ?(provider_extra = "")
      ?(model_extra = "max-prompt-bytes = 1048576")
      ()
  =
  Printf.sprintf
    "[providers.muse_code]\n\
     protocol = \"%s\"\n\
     %s\n\
     is-non-interactive = %b\n\
     %s\n\
     [models.muse-spark]\n\
     api-name = \"muse-spark-1.3\"\n\
     max-context = 1007997\n\
     %s\n\
     \n\
     [muse_code.muse-spark]\n\
     \n\
     [runtime]\n\
     default = \"%s\"\n"
    protocol
    transport
    non_interactive
    provider_extra
    model_extra
    runtime_id
;;

let with_runtime_toml content f =
  let path = Filename.temp_file "masc-muse-serve-config-" ".toml" in
  Out_channel.with_open_bin path (fun channel -> output_string channel content);
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

(* No official client anywhere, so a configured command stays as configured
   ({!Runtime_official_cli_install.locate}); these cases are about the
   configuration, not about where a client is installed. A blank
   MUSE_INSTALL_DIR reads as unset, which is what the lookup asks. *)
let without_an_installed_client f =
  let home = Filename.temp_dir "masc-no-client-" "" in
  let names = [ "PATH"; "HOME"; "MUSE_INSTALL_DIR" ] in
  let restore = List.map (fun name -> name, Sys.getenv_opt name) names in
  List.iter
    (fun (name, value) -> Unix.putenv name value)
    [ "PATH", ""; "HOME", home; "MUSE_INSTALL_DIR", "" ];
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, value) ->
           match value with
           | Some value -> Unix.putenv name value
           | None -> Unix.putenv name "")
        restore;
      Unix.rmdir home)
    f
;;

let load content =
  without_an_installed_client (fun () ->
    with_runtime_toml content (fun config_path ->
      Runtime.load_list ~config_path
      |> Result.map_error (Runtime.to_diagnostic_text ~config_path)))
;;

let parse_error_paths content =
  match Runtime_toml.parse_string content with
  | Ok _ -> []
  | Error errors -> List.map (fun (error : Runtime_toml.parse_error) -> error.path) errors
;;

let test_materializes_the_muse_serve_owner () =
  match load (runtime_toml ()) with
  | Error diagnostic -> failf "muse-serve did not load: %s" diagnostic
  | Ok (runtimes, default, _, _, _) ->
    check int "one runtime" 1 (List.length runtimes);
    check string "default" runtime_id default.id;
    check bool "the protocol is Muse Code's" true
      (Runtime_schema.equal_api_format
         default.provider.api_format
         Runtime_schema.Muse_serve_runtime);
    (match default.execution with
     | Runtime_execution.Muse_serve execution ->
       check string "the command, as configured when no client is installed" "muse"
         execution.cli_path;
       check string "the api-name is the session model" "muse-spark-1.3" execution.model;
       check (float 0.) "the serve client's own bound" Runtime_muse_serve.default_timeout_s
         execution.timeout_s
     | Runtime_execution.Agent_core _
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Claude_code _
     | Runtime_execution.Antigravity_cli _ ->
       fail "muse-serve was materialized as another execution owner");
    check string "execution label" "muse_serve" (Runtime_execution.label default.execution);
    check bool "the official client owns the session" true
      (Runtime_execution.checkpoint_owner default.execution
       = Runtime_execution.Official_client);
    check bool "built-in tools cannot be removed" false
      (Runtime_execution.supports_native_none default.execution)
;;

(* The adapter windows a start to [max-prompt-bytes] and refuses a turn
   without it, so a lane's byte budget counts the declaration. *)
let test_a_lane_budget_counts_the_declared_prompt_bytes () =
  check bool "muse-serve reads max-prompt-bytes" true
    (Runtime_schema.api_format_reads_max_prompt_bytes Runtime_schema.Muse_serve_runtime);
  let snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
      without_an_installed_client (fun () ->
        with_runtime_toml (runtime_toml ()) (fun config_path ->
          match Runtime.init_default ~config_path with
          | Error detail -> failf "muse-serve did not initialize: %s" detail
          | Ok () ->
            check (option int) "the declared ceiling bounds the lane" (Some 1048576)
              (Runtime.smallest_max_prompt_bytes_of_runtime_ids [ runtime_id ]))))
;;

let test_declared_credentials_are_refused () =
  let provider_extra =
    "[providers.muse_code.credentials]\ntype = \"env\"\nkey = \"META_API_KEY\"\n"
  in
  match load (runtime_toml ~provider_extra ()) with
  | Ok _ -> fail "muse-serve admitted a declared credential"
  | Error _ -> ()
;;

let test_an_http_endpoint_is_refused () =
  match load (runtime_toml ~transport:"endpoint = \"https://api.meta.ai/v1\"" ()) with
  | Ok _ -> fail "muse-serve admitted an HTTP endpoint"
  | Error _ -> ()
;;

let test_an_interactive_provider_is_refused () =
  match load (runtime_toml ~non_interactive:false ()) with
  | Ok _ -> fail "muse-serve admitted an interactive provider"
  | Error _ -> ()
;;

let test_provider_fields_of_other_clients_are_refused () =
  List.iter
    (fun (field, provider_extra) ->
       check bool (field ^ " is refused on muse-serve") true
         (List.mem
            ("providers.muse_code." ^ field)
            (parse_error_paths (runtime_toml ~provider_extra ()))))
    [ "account-home", "account-home = \"/tmp/muse-home\""
    ; "timeout-s", "timeout-s = 30.0"
    ]
;;

let test_the_protocol_name_is_exact () =
  (match Runtime_toml.api_format_of_protocol "muse-serve" with
   | Ok api_format ->
     check bool "muse-serve names Muse Code" true
       (Runtime_schema.equal_api_format api_format Runtime_schema.Muse_serve_runtime)
   | Error detail -> fail detail);
  match Runtime_toml.api_format_of_protocol "muse_serve" with
  | Ok _ -> fail "an underscore spelling was accepted"
  | Error _ -> ()
;;

let () =
  run
    "runtime_muse_serve_config"
    [ ( "muse-serve"
      , [ test_case "materializes the muse-serve owner" `Quick
            test_materializes_the_muse_serve_owner
        ; test_case "a lane budget counts the declared prompt bytes" `Quick
            test_a_lane_budget_counts_the_declared_prompt_bytes
        ; test_case "declared credentials are refused" `Quick
            test_declared_credentials_are_refused
        ; test_case "an HTTP endpoint is refused" `Quick test_an_http_endpoint_is_refused
        ; test_case "an interactive provider is refused" `Quick
            test_an_interactive_provider_is_refused
        ; test_case "provider fields of other clients are refused" `Quick
            test_provider_fields_of_other_clients_are_refused
        ; test_case "the protocol name is exact" `Quick test_the_protocol_name_is_exact
        ] )
    ]
;;
