open Alcotest

(* The [vibe-cli] protocol in runtime.toml: what a declaration becomes, and
   which declarations are refused. Assertions on refusals read the typed
   failure or the parse error's path, not its wording. *)

let runtime_id = "mistral_vibe.vibe-model"

let runtime_toml
      ?(transport = "command = \"vibe\"")
      ?(non_interactive = true)
      ?(provider_extra = "")
      ?(model_extra = "")
      ()
  =
  Printf.sprintf
    "[providers.mistral_vibe]\n\
     protocol = \"vibe-cli\"\n\
     %s\n\
     is-non-interactive = %b\n\
     %s\n\
     [models.vibe-model]\n\
     api-name = \"vibe-model-alias\"\n\
     max-context = 262144\n\
     %s\n\
     \n\
     [mistral_vibe.vibe-model]\n\
     \n\
     [runtime]\n\
     default = \"%s\"\n"
    transport
    non_interactive
    provider_extra
    model_extra
    runtime_id
;;

let with_runtime_toml content f =
  let path = Filename.temp_file "masc-vibe-cli-config-" ".toml" in
  Out_channel.with_open_bin path (fun channel -> output_string channel content);
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

(* A binding the adapter cannot build is dropped, not fatal, so the default
   that names it is what the load refuses. *)
let check_binding_dropped (label, content) =
  with_runtime_toml content (fun config_path ->
    match Runtime.load_list ~config_path with
    | Ok _ -> failf "%s: vibe-cli admitted it" label
    | Error
        (Runtime_config_error.Default_runtime_unresolved
          { unresolved_id; declared_drop = Some (Runtime_config_error.Execution_unbuildable _); _ }) ->
      check string (label ^ ": the default names the dropped binding") runtime_id unresolved_id
    | Error failure ->
      failf "%s: refused for another reason: %s" label
        (Runtime_config_error.to_diagnostic_text ~config_path failure))
;;

let test_materializes_the_vibe_owner () =
  with_runtime_toml (runtime_toml ()) (fun config_path ->
    match Runtime.load_list ~config_path with
    | Error failure ->
      failf "vibe-cli did not load: %s"
        (Runtime_config_error.to_diagnostic_text ~config_path failure)
    | Ok (_, default, _, _, _) ->
      (match default.execution with
       | Runtime_execution.Vibe_cli execution ->
         check string "the command is spawned as configured" "vibe" execution.cli_path;
         check string "the api-name is Vibe's --model" "vibe-model-alias" execution.model
       | Runtime_execution.Agent_core _
       | Runtime_execution.Codex_app_server _
       | Runtime_execution.Claude_code _
       | Runtime_execution.Antigravity_cli _
       | Runtime_execution.Muse_serve _ ->
         fail "vibe-cli was materialized as another execution owner");
      check (option string) "Vibe is absent from exact-output slot groups" None
        (Runtime.exact_slot_list_key_of_api_format default.provider.api_format);
      check bool "the official client owns the call" true
        (Runtime_execution.checkpoint_owner default.execution
         = Runtime_execution.Official_client))
;;

let test_declarations_vibe_cannot_hold_are_refused () =
  List.iter
    check_binding_dropped
    [ ( "a declared credential"
      , runtime_toml
          ~provider_extra:
            "[providers.mistral_vibe.credentials]\ntype = \"env\"\nkey = \"MISTRAL_API_KEY\"\n"
          () )
    ; "an HTTP endpoint", runtime_toml ~transport:"endpoint = \"https://api.mistral.ai/v1\"" ()
    ; "an interactive provider", runtime_toml ~non_interactive:false ()
    ; "a reasoning effort", runtime_toml ~model_extra:"reasoning-effort = \"low\"" ()
    ; "a turn deadline", runtime_toml ~model_extra:"turn-timeout-s = 600.0" ()
    ; "an explicit no-deadline", runtime_toml ~model_extra:"turn-timeout-s = 0.0" ()
    ]
;;

let test_account_home_is_refused_at_parse () =
  match
    Runtime_toml.parse_string (runtime_toml ~provider_extra:"account-home = \"/synthetic/vibe\"" ())
  with
  | Ok _ -> fail "account-home was accepted on vibe-cli"
  | Error errors ->
    check bool "the error names account-home" true
      (List.exists
         (fun (error : Runtime_toml.parse_error) ->
            String.equal error.path "providers.mistral_vibe.account-home")
         errors)
;;

let () =
  run
    "runtime_vibe_cli_config"
    [ ( "vibe-cli"
      , [ test_case "materializes the vibe owner" `Quick test_materializes_the_vibe_owner
        ; test_case "declarations Vibe cannot hold are refused" `Quick
            test_declarations_vibe_cannot_hold_are_refused
        ; test_case "account-home is refused at parse" `Quick
            test_account_home_is_refused_at_parse
        ] )
    ]
;;
