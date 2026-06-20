(* Fusion — OAS 호출 공유 글루 (구현).
   계약/문서: fusion_oas.mli, docs/rfc/RFC-0252 §7

   OAS 범용 함수만 소비: Runtime_oas_runner(id→provider) → Runtime_agent(build).
   fusion 개념은 OAS에 노출하지 않는다. *)

let answer_text (resp : Agent_sdk.Types.api_response) : string =
  resp.content
  |> List.filter_map (function Agent_sdk.Types.Text s -> Some s | _ -> None)
  |> String.concat "\n"

let usage_of (resp : Agent_sdk.Types.api_response) : Fusion_types.usage =
  match resp.usage with
  | Some u ->
    { Fusion_types.input_tokens = u.Agent_sdk.Types.input_tokens
    ; output_tokens = u.Agent_sdk.Types.output_tokens
    }
  | None -> Fusion_types.zero_usage

let provider_error_detail ~runtime_id detail =
  let runtime_id = String.trim runtime_id in
  let detail = String.trim detail in
  if String.equal runtime_id "" || String.equal detail "" then detail
  else
    let unknown_prefix = "Provider 'unknown'" in
    let runtime_provider_prefix = Printf.sprintf "Provider '%s'" runtime_id in
    let runtime_context_prefix = runtime_id ^ ": " in
    if String.starts_with ~prefix:unknown_prefix detail then
      runtime_provider_prefix
      ^ String.sub detail (String.length unknown_prefix)
          (String.length detail - String.length unknown_prefix)
    else if String.starts_with ~prefix:runtime_provider_prefix detail
            || String.starts_with ~prefix:runtime_context_prefix detail
    then detail
    else Printf.sprintf "%s: %s" runtime_id detail

let timeout_budget_opt timeout_s =
  if Float.is_finite timeout_s && timeout_s > 0.0 then Some timeout_s else None

let apply_timeout_budget ?timeout_s (base_config : Runtime_agent.config) =
  match Option.bind timeout_s timeout_budget_opt with
  | None -> base_config
  | Some timeout_s ->
    (* Fusion owns the structural wall-clock budget via the outer
       Masc_oas_bridge.run_safe call. Do not arm Runtime_agent's total
       max_execution_time_s here; it can kill an active stream with the
       wrong failure attribution. *)
    { base_config with
      Runtime_agent.stream_idle_timeout_s = Some timeout_s
    ; body_timeout_s = Some timeout_s
    }

(** [Keeper_tool_descriptor]에서 날것의 web tool descriptor를 찾아
    [Agent_sdk.Tool.t]로 변환한다. 패널/심판이 web_search/web_fetch를
    호출할 수 있게 하는 목적으로만 쓰인다. *)
let oas_tool_of_descriptor (d : Keeper_tool_descriptor.t) : Agent_sdk.Tool.t option =
  let handler args =
    let start_time = Unix.gettimeofday () in
    match d.Keeper_tool_descriptor.internal_name with
    | "masc_web_search" ->
      Tool_misc_web_search.handle ~tool_name:d.internal_name ~start_time args
    | "masc_web_fetch" ->
      Tool_misc_web_fetch.handle ~tool_name:d.internal_name ~start_time args
    | _ ->
      Tool_result.make_err
        ~tool_name:d.internal_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        "fusion: unsupported web tool"
  in
  Some
    (Tool_bridge.oas_tool_of_masc
       ~name:d.internal_name
       ~description:d.description
       ~input_schema:d.input_schema
       handler)

let web_tool_bundle () : Agent_sdk.Tool.t list =
  [ "masc_web_search"; "masc_web_fetch" ]
  |> List.map Keeper_tool_descriptor.descriptors_for_internal
  |> List.concat
  |> List.filter_map oas_tool_of_descriptor

let build_agent ~sw ~net ~system_prompt ?(tools = []) ?(max_tool_calls = 0)
    ?timeout_s (model : string)
  : (Agent_sdk.Agent.t, Fusion_types.panel_failure) result
  =
  match Runtime_oas_runner.resolve_runtime_providers ~runtime_id:model () with
  | Error e -> Error (Fusion_types.Provider_error e)
  | Ok [] -> Error (Fusion_types.Provider_error (model ^ ": no provider config"))
  | Ok (provider_cfg :: _) ->
    (* v1: runtime이 여러 provider를 주면 첫 번째만(단일 provider 가정). *)
    let base_config =
      Runtime_agent.default_config ~name:model ~provider_cfg ~system_prompt ~tools
    in
    let base_config = apply_timeout_budget ?timeout_s base_config in
    (* max_tool_calls는 OpenRouter Fusion의 per-panel tool budget에 대응.
       Runtime_agent의 max_turns로 근사: tool 호출 횟수 + 최종 답변 1턴. *)
    let config =
      if max_tool_calls > 0 then { base_config with max_turns = max_tool_calls + 1 }
      else base_config
    in
    (match Runtime_agent.build ~sw ~net ~config with
     | Ok agent -> Ok agent
     | Error e ->
       Error
         (Fusion_types.Provider_error
            (provider_error_detail ~runtime_id:model (Agent_sdk.Error.to_string e))))

module For_testing = struct
  let apply_timeout_budget = apply_timeout_budget
end
