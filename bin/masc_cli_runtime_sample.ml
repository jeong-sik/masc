(** Explicit, tool-free conversations through the configured Agent Core runtime.
    This is a sampling harness, not a provider adapter or a correctness judge. *)
module T = Agent_core.Types

type scenario = { system_prompt : string; prompts : string list }

let parse_scenario = function
  | `Assoc fields ->
      let rec strings = function
        | [] -> Ok []
        | `String s :: rest -> Result.map (fun tail -> s :: tail) (strings rest)
        | _ -> Error "prompts must be an array of strings"
      in
      (match List.assoc_opt "system_prompt" fields, List.assoc_opt "prompts" fields with
       | Some (`String system_prompt), Some (`List (_ :: _ as prompts)) ->
           Result.map (fun prompts -> { system_prompt; prompts }) (strings prompts)
       | _ -> Error "scenario requires system_prompt:string and nonempty prompts:string[]")
  | _ -> Error "scenario must be a JSON object"

let emit fields =
  print_endline (Yojson.Safe.to_string (`Assoc fields));
  flush stdout

let nullable encode = function None -> `Null | Some x -> encode x

let sample ~sw ~net ~scenario ~run_id ~sample_index ~runtime_id =
  let report status fields =
    emit (("run_id", `String run_id) :: ("sample_index", `Int sample_index) :: ("runtime_id", `String runtime_id)
          :: ("status", `String status) :: fields)
  in
  let failure ?turn kind detail =
    report "failed"
      ([ "failure_kind", `String kind; "detail", `String detail ]
       @ (match turn with None -> [] | Some index -> [ "turn", `Int index ]));
    false
  in
  match Runtime.get_runtime_by_id runtime_id with
  | None -> failure "runtime_unavailable" "Runtime is absent from the initialized configuration"
  | Some runtime ->
      match runtime.execution with
      | Runtime_execution.Claude_code _
      | Runtime_execution.Codex_app_server _
      | Runtime_execution.Antigravity_cli _ ->
          report "not_supported"
            [ "reason", `String "This sampler requires Agent Core execution; CLI transports have separate session semantics" ];
          false
      | Runtime_execution.Agent_core _ ->
          match Runtime_agent_core_runner.resolve_runtime_providers_for_turn ~runtime_id () with
          | Error detail -> failure "runtime_resolution" detail
          | Ok [ provider_cfg ] ->
              let config =
                { (Runtime_agent.default_config ~name:"runtime-token-sample"
                     ~provider_cfg ~system_prompt:scenario.system_prompt ~tools:[]) with
                  runtime_id = Some runtime_id }
              in
              let rec turns index history = function
                | [] -> report "completed" [ "turns", `Int (index - 1) ]; true
                | prompt :: rest ->
                    let failure = failure ~turn:index in
                    report "started" [ "turn", `Int index; "prompt", `String prompt ];
                    match Runtime_agent.run ~sw ~net
                            ~config:{ config with initial_messages = history } prompt with
                    | Error err -> failure "agent_core" (Agent_core.Error.to_string err)
                    | Ok result ->
                        let response = result.response in
                        report "response"
                          [ "turn", `Int index
                          ; "response_id", `String response.id
                          ; "model", `String response.model
                          ; "stop_reason", `String (T.stop_reason_to_string response.stop_reason)
                          ; "usage", nullable T.api_usage_to_yojson response.usage
                          ; "telemetry", nullable T.inference_telemetry_to_yojson response.telemetry
                          ; "output", `String (T.text_of_response response)
                          ];
                        (match result.stop_reason, response.stop_reason with
                         | Runtime_agent.Completed, (T.EndTurn | T.StopSequence) ->
                             (match T.assistant_message_of_response response with
                              | Error _ ->
                                  failure "history_provenance_missing"
                                    "Cannot replay reasoning without provider provenance"
                              | Ok assistant ->
                                  turns (index + 1) (history @ [ T.user_msg prompt; assistant ]) rest)
                         | _ -> failure "incomplete_turn"
                                  "Execution did not finish a complete assistant turn")
              in
              turns 1 [] scenario.prompts
          | Ok _ -> failure "runtime_resolution" "Expected one provider for an exact runtime ID"

let run ~config_path ~scenario_path ~runtime_ids =
  let scenario =
    try
      let source = In_channel.with_open_bin scenario_path In_channel.input_all in
      Result.map (fun scenario -> source, scenario)
        (parse_scenario (Yojson.Safe.from_string source))
    with
    | Sys_error detail | Yojson.Json_error detail -> Error detail
  in
  match scenario with
  | Error detail -> Log.Runtime.error "runtime-token-sample: %s" detail; 1
  | Ok (scenario_source, scenario) ->
      let observation =
        try
          let (_ : string option) =
            Server_runtime_bootstrap.configure_agent_core_model_catalog_env ()
          in
          let (_ : string option) =
            Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
              ~config_root:(Filename.dirname config_path) ()
          in
          Runtime.load_config_observation ~runtime_config_path:config_path ()
        with Env_config_core.Config_error detail -> Error detail
      in
      match observation with
      | Error detail -> Log.Runtime.error "runtime-token-sample: %s" detail; 1
      | Ok observation ->
          match Runtime.init_default_degraded_observation observation with
          | Error err -> Log.Runtime.error "runtime-token-sample: %s" (Runtime.strict_init_error_to_string err); 1
          | Ok outcome ->
              let degradation = match outcome with
                | Runtime.Initialized -> None
                | Runtime.Initialized_degraded degradation -> Some degradation
              in
              let identity = Masc.Build_identity.current () in
              let run_id = identity.runtime_instance_id in
              emit
                [ "kind", `String "manifest"
                ; "run_id", `String run_id
                ; "binary_commit", nullable (fun s -> `String s) identity.binary_commit
                ; "executable_sha256", nullable (fun s -> `String s) identity.executable_sha256
                ; "provenance_source", `String identity.provenance_source
                ; "source_fingerprint", nullable (fun s -> `String s) identity.source_fingerprint
                ; "started_at", `String identity.started_at
                ; "scenario_source_sha256", `String Digestif.SHA256.(to_hex (digest_string scenario_source))
                ; "schema_version", `Int 1
                ; "config_revision", `String (Runtime.config_source_revision_to_string observation.source_revision)
                ; "startup_degradation", Runtime.startup_degradation_to_yojson degradation
                ; "runtime_ids", `List (List.map (fun id -> `String id) runtime_ids)
                ; "system_prompt", `String scenario.system_prompt
                ; "prompts", `List (List.map (fun prompt -> `String prompt) scenario.prompts)
                ; "usage_scope", `String "Agent Core normalized terminal response; not a ledger of HTTP retries"
                ];
              Eio_main.run (fun env ->
                Eio.Switch.run (fun sw ->
                  Eio_context.set_env env;
                  Eio_context.set_switch sw;
                  Eio_context.set_net (Eio.Stdenv.net env);
                  Eio_context.set_clock (Eio.Stdenv.clock env);
                  Eio_context.set_mono_clock (Eio.Stdenv.mono_clock env);
                  let outcomes = List.mapi
                    (fun index runtime_id -> sample ~sw ~net:(Eio.Stdenv.net env)
                        ~scenario ~run_id ~sample_index:(index + 1) ~runtime_id) runtime_ids in
                  if List.for_all Fun.id outcomes then 0 else 1))
