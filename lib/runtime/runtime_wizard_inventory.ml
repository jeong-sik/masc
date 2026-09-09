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
               | Some (Runtime_schema.Env name) -> [ "api_key_env", `String name ]
               | Some (Runtime_schema.File _ | Runtime_schema.Inline _) | None -> []
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
