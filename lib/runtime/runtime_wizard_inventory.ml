let to_json (config : Runtime_schema.config) =
  let runtimes =
    List.filter_map
      (fun (binding : Runtime_schema.binding) ->
         if not binding.enabled
         then None
         else (
           match
             ( List.find_opt
                 (fun (p : Runtime_schema.provider) ->
                    p.id = binding.provider_id && p.enabled)
                 config.providers
             , List.find_opt
                 (fun (m : Runtime_schema.model_spec) -> m.id = binding.model_id)
                 config.models )
           with
           | Some provider, Some model ->
             let transport =
               match provider.transport with
               | Runtime_schema.Cli command -> [ "command", `String command ]
               | Runtime_schema.Http endpoint ->
                 let uri = Uri.of_string endpoint in
                 if
                   Uri.userinfo uri <> None
                   || Uri.query uri <> []
                   || Uri.fragment uri <> None
                 then [ "endpoint_redacted", `Bool true ]
                 else [ "endpoint", `String endpoint ]
             in
             let credential =
               match provider.credentials with
               | Some (Runtime_schema.Env name) ->
                 [ "credential_kind", `String "env"; "api_key_env", `String name ]
               | Some (Runtime_schema.File _) -> [ "credential_kind", `String "file" ]
               | Some (Runtime_schema.Inline _) -> [ "credential_kind", `String "inline" ]
               | None -> [ "credential_kind", `String "none" ]
             in
             Some
               (`Assoc
                   ([ "id", `String (Runtime_schema.binding_key binding)
                    ; "provider_id", `String provider.id
                    ; "display_name", `String provider.display_name
                    ; "protocol", `String provider.protocol
                    ; "model", `String model.api_name
                    ; ( "max_context"
                      , match model.max_context with
                        | None -> `Null
                        | Some n -> `Int n )
                    ; "tools", `Bool model.tools_support
                    ; "streaming", `Bool model.streaming
                    ]
                    @ transport
                    @ credential))
           | _ -> None))
      config.bindings
  in
  `Assoc
    [ ( "default_runtime_id"
      , match config.default_runtime_id with
        | None -> `Null
        | Some id -> `String id )
    ; "runtimes", `List runtimes
    ]
;;


let binding_for_provider (cfg : Runtime_schema.config)
    (provider : Runtime_schema.provider) =
  let bindings =
    List.filter
      (fun (binding : Runtime_schema.binding) ->
         binding.enabled && String.equal binding.provider_id provider.id)
      cfg.bindings
  in
  match bindings with
  | [] -> Error (Printf.sprintf "provider %s has no concrete runtime binding" provider.id)
  | _ ->
      (match List.filter (fun (binding : Runtime_schema.binding) -> binding.wizard_default) bindings with
       | [ binding ] -> Ok binding
       (* One enabled binding is the default by arithmetic: there is nothing
          else the wizard could install, so requiring the operator to say so
          rejects a config the server boots from (#27991, live glm-coding).
          Two or more without a flag stays an error -- that one is a real
          choice and guessing it would install a model nobody picked. *)
       | [] when List.length bindings = 1 -> Ok (List.hd bindings)
       | [] ->
           (* Prefer the binding the config already runs by default: that is the
              operator's own pick, not a guess, so a live config with several
              bindings and one [runtime].default no longer fails the wizard.
              Only when this provider does not own the default runtime is the
              choice genuinely ambiguous, and then it stays an error the caller
              skips rather than guessing a model nobody picked. *)
           (match
              (match cfg.default_runtime_id with
               | None -> None
               | Some runtime_id ->
                   List.find_opt
                     (fun (binding : Runtime_schema.binding) ->
                        String.equal
                          (Runtime_schema.binding_key binding)
                          runtime_id)
                     bindings)
            with
            | Some binding -> Ok binding
            | None ->
                Error
                  (Printf.sprintf
                     "provider %s has %d enabled bindings and no install wizard default; set wizard-default = true on exactly one [%s.<model>] binding"
                     provider.id (List.length bindings) provider.id))
       | defaults ->
           Error
             (Printf.sprintf
                "provider %s has %d install wizard default bindings; set wizard-default = true on exactly one [%s.<model>] binding"
                provider.id
                (List.length defaults)
                provider.id))
;;
