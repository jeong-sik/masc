(** Keeper_turn_driver_wrappers — convenience wrappers extracted from
    [Keeper_turn_driver].

    These are sibling entry points to {!Keeper_turn_driver.run_named}:
    - [run_model_by_label]: explicit model-label variant
    - [run_named_with_masc_tools]: runtime variant + MASC tool bridging
    - [run_model_with_masc_tools]: model-label variant + MASC tool bridging

    Extracted from keeper_turn_driver.ml as RFC-0048 PR-2 to reduce the
    1347-LOC hotspot file.

    @since RFC-0048 PR-2 *)

open Result.Syntax
include Keeper_turn_driver

(* RFC-0206: re-homed from the deleted Runtime_config_builder.  Resolves a model
   label to its provider config and builds a Runtime_agent.config; no runtime
   catalog involved. *)
let config_for_label
    ~(name : string)
    ~(model_label : string)
    ~(system_prompt : string)
    ~(tools : Agent_sdk.Tool.t list)
    ~(max_tokens : int option)
    ~(temperature : float)
    ?stream_idle_timeout_s
    ?hooks
    ?enable_thinking
    ?provider_config_transform
    ~(description : string option)
    () : (Runtime_agent.config, Agent_sdk.Error.sdk_error) result =
  let* provider =
    Runtime_agent.resolve_provider_config_of_label model_label
    |> Result.map_error Runtime_agent.label_resolution_error_to_sdk_error
  in
  let* provider =
    match provider_config_transform with
    | None -> Ok provider
    | Some transform -> transform provider
  in
  Ok
    {
      (Runtime_agent.default_config ~name ~provider_cfg:provider
         ~system_prompt ~tools)
      with
      max_tokens;
      temperature;
      stream_idle_timeout_s;
      hooks;
      enable_thinking;
      description;
    }

let run_model_by_label
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ?(tools = [])
    ?stream_idle_timeout_s
    ?(temperature = Runtime_provider_defaults.agent_default_temperature)
    ?max_tokens
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?hooks
    ?enable_thinking
    ?provider_config_transform
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  let* config =
    config_for_label ~name:"oas-label-model" ~model_label ~system_prompt
      ~tools ~max_tokens ~temperature
      ?stream_idle_timeout_s ?hooks
      ?enable_thinking
      ?provider_config_transform
      ~description:(Some (Printf.sprintf "model_label:%s" model_label))
      ()
  in
  match Runtime_oas_runner.require_eio ?sw ?net () with
  | Error e -> Error (Runtime_oas_runner.eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config = { config with transport = transport_resolved } in
      Inference_inflight_observation.with_observation
          ~keeper_name:"oas-label-model"
          ~runtime_id:model_label
          (fun () ->
            match Runtime_agent.run ~sw ~net ~config ?on_event goal with
                | Ok result when accept result.response -> Ok result
                | Ok result ->
                    let rejection =
                      Keeper_tool_response.accept_rejection_of_response
                        (* RFC-0132-EXEMPT: internal observability *)
                        ~runtime_id:"runtime"
                        result.response
                    in
                    let reason_kind =
                      match rejection.kind with
                      | Keeper_tool_response.No_usable_progress ->
                        Some Accept_no_usable_progress
                      | Keeper_tool_response.Predicate_rejected ->
                        Some Accept_predicate_rejected
                    in
                    Error
                      (sdk_error_of_masc_internal_error
                         (Accept_rejected
                            {
                              scope = model_label;
                              (* RFC-0132 PR-2: model field = external boundary; redact via SSOT.
                                 The reason format string keeps the literal runtime label as
                                 debug content (excluded from codemod — internal observability). *)
                              model =
                                Some
                                  (Boundary_redaction.to_string
                                     Boundary_redaction.runtime_model_label);
                              reason_kind;
                              response_shape =
                                Option.map
                                  accept_response_shape_of_agent_sdk
                                  rejection.response_shape;
                              (* RFC-0271 §4.5: preserve provider stop_reason. *)
                              stop_reason = Some result.response.stop_reason;
                              reason = rejection.reason;
                            }))
                | Error e -> Error e)

let run_named_with_masc_tools
    ~runtime_id
    ?(keeper_name = "")
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ?stream_idle_timeout_s
    ?(temperature = Runtime_provider_defaults.agent_default_temperature)
    ?(accept = fun (_ : Agent_sdk_response.api_response) -> true)
    ?hooks
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?transport
    ?(yield_on_tool = false)
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  let oas_tools = List.map (fun (td : Masc_domain.tool_schema) ->
    Tool_bridge.oas_tool_of_masc
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  Keeper_turn_driver.run_named ~runtime_id ~keeper_name ~goal ~system_prompt ~tools:oas_tools
    ~temperature
    ?stream_idle_timeout_s ?hooks
    ~accept
    ?raw_trace ?on_event ?on_yield ?on_resume 
    ?transport ~yield_on_tool ?provider_config_transform ?sw ?net ()

let run_model_with_masc_tools
    ~(model_label : string)
    ~goal
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ?stream_idle_timeout_s
    ?(temperature = Runtime_provider_defaults.agent_default_temperature)
    ?max_tokens
    ?hooks
    ?enable_thinking
    ?provider_config_transform
    ?raw_trace
    ?on_event
    ?transport
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_sdk.Error.sdk_error) result =
  let* config =
    config_for_label ~name:"oas-explicit-model" ~model_label ~system_prompt
      ~tools:[] ~max_tokens ~temperature
      ?stream_idle_timeout_s ?hooks ?enable_thinking
      ?provider_config_transform
      ~description:(Some (Printf.sprintf "model_label:%s" model_label))
      ()
  in
  match Runtime_oas_runner.require_eio ?sw ?net () with
  | Error e -> Error (Runtime_oas_runner.eio_context_error_to_sdk_error e)
  | Ok (sw, net) ->
      let transport_resolved = match transport with
        | Some t -> t
        | None -> Masc_grpc_transport.from_env ()
      in
      let config = { config with raw_trace; transport = transport_resolved } in
      Inference_inflight_observation.with_observation
          ~keeper_name:"oas-explicit-model"
          ~runtime_id:model_label
          (fun () ->
            Runtime_agent.run_with_masc_tools ~sw ~net ~config ~masc_tools
              ~dispatch ?on_event goal)
