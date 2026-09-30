module S = Mcp_protocol.Sampling
module L = Llm_provider.Types
let ( let* ) = Result.bind

type control = Output_limit | Stop_sequences | Sampling_tools | Temperature
type failure =
  | Runtime_unavailable of string
  | Unsupported_controls of control list
  | Invalid_request of string
  | Provider_error of Llm_provider.Http_client.http_error

let control_name = function
  | Output_limit -> "max_tokens"
  | Stop_sequences -> "stop_sequences"
  | Sampling_tools -> "sampling_tools"
  | Temperature -> "temperature"

let provider_error_detail = function
  | Llm_provider.Http_client.HttpError {code;body;retry_after_header=_} ->
      Printf.sprintf "HTTP %d: %s" code (Llm_provider.Http_client.refusal_body_text body)
  | Llm_provider.Http_client.NetworkError {message;kind=_}
  | Llm_provider.Http_client.TimeoutError {message;phase=_}
  | Llm_provider.Http_client.ProviderTerminal {message;kind=_}
  | Llm_provider.Http_client.ProviderFailure {message;kind=_} -> message
  | Llm_provider.Http_client.AcceptRejected {reason} -> reason

let failure_detail = function
  | Runtime_unavailable detail | Invalid_request detail -> detail
  | Unsupported_controls controls ->
      "Selected runtime cannot enforce sampling controls: "
      ^ String.concat ", " (List.map control_name controls)
  | Provider_error error -> provider_error_detail error

let route_of_binding = function
  | `Assoc fields -> (match List.assoc_opt "model_route" fields with
      | Some (`String route) when String.trim route<>"" -> Ok route
      | Some _ | None -> Error "host sampling requires binding.model_route")
  | _ -> Error "host sampling requires an object binding"

let route_candidates route =
  match Runtime.resolve_assignment route with
  | `Lane lane -> (match Runtime_lane.ordered_candidates lane with
      | [] -> Error "host model route has no configured candidates"
      | candidates -> Ok candidates)
  | `Unavailable missing -> Error (Runtime.missing_catalog_model_to_string missing)
  | `Missing -> Error ("host model route is not configured: " ^ route)

let unsupported_common (params : S.create_message_params) =
  let stops = match params.stop_sequences with None | Some [] -> [] | Some (_ :: _) -> [Stop_sequences] in
  let tools = match params.tools,params.tool_choice with
    | (None | Some []), (None | Some S.None_) -> []
    | (None | Some [] | Some (_ :: _)), (None | Some S.None_ | Some S.Auto | Some (S.Tool _)) -> [Sampling_tools] in
  stops @ tools

let native_messages (params : S.create_message_params) =
  List.map (fun (message : S.sampling_message) ->
    let role = match message.role with S.User -> L.User | S.Assistant -> L.Assistant in
    let content = match message.content with
      | S.Text {text;type_=_} -> L.Text text
      | S.Image {data;mime_type;type_=_} ->
          L.Image {media_type=mime_type;data;source_type=L.Base64} in
    {L.role=role;content=[content];name=None;tool_call_id=None;metadata=[]}) params.messages

let sampling_stop_reason = function
  | L.EndTurn -> Some "endTurn"
  | L.MaxTokens -> Some "maxTokens"
  | L.StopSequence -> Some "stopSequence"
  | L.StopToolUse | L.Refusal | L.ContentFilter | L.RepetitionTruncation
  | L.PauseTurn | L.Compaction | L.ContextWindowExceeded | L.UnmatchedToolCalls
  | L.Unknown _ -> None

let native_attempt ~sw ~net ~runtime_id (params : S.create_message_params) =
  let controls = unsupported_common params in
  let* () = if controls=[] then Ok () else Error (Unsupported_controls controls) in
  let* () = match params.temperature with
    | Some value when not (Float.is_finite value) -> Error (Invalid_request "sampling temperature must be finite")
    | Some _ | None -> Ok () in
  let* providers = Runtime_agent_core_runner.resolve_runtime_providers_for_turn ~runtime_id ()
    |> Result.map_error (fun detail -> Runtime_unavailable detail) in
  let* provider = match providers with
    | [provider] -> Ok provider
    | [] | _ :: _ :: _ -> Error (Runtime_unavailable "runtime did not resolve one exact provider binding") in
  let config = {provider with Llm_provider.Provider_config.max_tokens=Some params.max_tokens;
    temperature=(match params.temperature with
      | Some value -> Some (Runtime_inference.resolve_temperature ~runtime_id ~fallback:(fun () -> value))
      | None -> (match Runtime.temperature_of_runtime_id runtime_id with
          | Some value -> Some value | None -> provider.temperature));
    system_prompt=(match params.system_prompt with Some prompt -> Some prompt | None -> provider.system_prompt)} in
  let* clock = Eio_context.get_clock () |> Result.map_error (fun detail -> Runtime_unavailable detail) in
  let body_timeout_s = Runtime_inference.resolve_turn_timeout_s ~runtime_id in
  let* response = Llm_provider.Complete.complete ~sw ~net ~clock ~config
    ~messages:(native_messages params) ?body_timeout_s ()
    |> Result.map_error (fun error -> Provider_error error) in
  let text = L.visible_text_of_response response in
  let* () = if String.trim text = "" then
      Error (Provider_error (Llm_provider.Http_client.empty_completion_error
        ~stop_reason:response.stop_reason))
    else Ok () in
  Ok {S.role=S.Assistant;content=S.Text {type_="text";text};
    model=response.model;stop_reason=sampling_stop_reason response.stop_reason;
    _meta=Some (`Assoc ["masc.lane_provider",`Assoc ["stop_reason",
      `String (L.stop_reason_to_string response.stop_reason)]])}

let attempt ~sw ~net ~runtime_id params =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> Error (Runtime_unavailable ("configured candidate is unavailable: " ^ runtime_id))
  | Some runtime -> match runtime.Runtime.execution with
      | Runtime_execution.Agent_core _ -> native_attempt ~sw ~net ~runtime_id params
      | Runtime_execution.Codex_app_server _ | Runtime_execution.Claude_code _
      | Runtime_execution.Antigravity_cli _ | Runtime_execution.Muse_serve _ ->
          let temperature = match params.S.temperature with None -> [] | Some _ -> [Temperature] in
          Error (Unsupported_controls (Output_limit :: (unsupported_common params @ temperature)))

let invoke ~sw ~net ~route ~request:_ params =
  let* candidates = route_candidates route in
  let rec walk failures = function
    | [] -> Error (Yojson.Safe.to_string (`Assoc ["route",`String route;
        "attempts",`List (List.rev failures)]))
    | runtime_id :: rest ->
        match attempt ~sw ~net ~runtime_id params with
        | Error failure ->
            let stop = match failure with
              | Provider_error (Llm_provider.Http_client.ProviderFailure
                  {kind=Empty_completion {stop_reason};message=_}) ->
                  ["provider_stop_reason", `String (L.stop_reason_to_string stop_reason)]
              | Runtime_unavailable _ | Unsupported_controls _ | Invalid_request _
              | Provider_error _ -> [] in
            walk (`Assoc (["runtime_id",`String runtime_id;
              "error",`String (failure_detail failure)] @ stop) :: failures) rest
        | Ok answer ->
            let metadata = match answer.S._meta with
              | Some (`Assoc fields) -> fields
              | Some _ | None -> [] in
            Ok {answer with S._meta=Some (`Assoc (("masc.lane_host",`Assoc [
              "route",`String route;"runtime_id",`String runtime_id;
              "failed_attempts",`List (List.rev failures)])
              :: List.remove_assoc "masc.lane_host" metadata))} in
  walk [] candidates

let create_handler ~config ~net ~sw ~store ~instance_id ~package ~binding =
  let owned_store = Filename.concat (Workspace.masc_dir config) "lane-addons" in
  let* () = if String.equal (Lane_addon_store.root store) owned_store then Ok ()
    else Error "sampling worker store does not belong to the registered workspace" in
  let* route = route_of_binding binding in
  let* _candidates = route_candidates route in
  Lane_addon_sampling.create ~store ~package ~instance_id ~route
    ~invoke:(invoke ~sw ~net) ()

let register ~config ~net =
  Lane_addon_runtime.register_sampling_factory
    (create_handler ~config ~net)
