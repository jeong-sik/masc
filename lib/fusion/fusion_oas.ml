(* Fusion — OAS 호출 공유 글루 (구현).
   계약/문서: fusion_oas.mli, docs/rfc/RFC-0252 §7

   OAS 범용 함수만 소비: Runtime_oas_runner(id→provider) → Runtime_agent(build).
   fusion 개념은 OAS에 노출하지 않는다. *)

let answer_text (resp : Agent_sdk.Types.api_response) : string =
  Agent_sdk_response.text_of_response resp

let stop_reason_label = Keeper_hooks_oas_types.stop_reason_to_label

(* 콘텐츠 블록 카운팅은 OAS canonical projection
   [Agent_sdk.Response_shape.summarize_blocks]에 위임한다. 로컬 fold를 재구현하지 않는다
   (keeper_hooks_oas_types.ml의 F2 canonical projection 원칙과 동일 — 미이행 사이트였다).
   thinking_kind 분류만 MASC가 소유한다: OAS는 model-family thinking 의미를 의도적으로
   노출하지 않으므로 [summarize_thinking_blocks]로 별도 산출한다. *)
let empty_response_detail (resp : Agent_sdk.Types.api_response) : string =
  let shape = Agent_sdk.Response_shape.summarize_blocks resp.content in
  let thinking = Keeper_hooks_oas_types.summarize_thinking_blocks resp.content in
  let input_tokens, output_tokens =
    match resp.usage with
    | Some u -> string_of_int u.input_tokens, string_of_int u.output_tokens
    | None -> "unknown", "unknown"
  in
  Printf.sprintf
    "empty response (stop_reason=%s content_blocks=%d text_blocks=%d \
     text_chars=%d thinking_kind=%s thinking_blocks=%d thinking_chars=%d \
     redacted_thinking_blocks=%d tool_use_count=%d tool_result_count=%d \
     image_count=%d document_count=%d audio_count=%d input_tokens=%s \
     output_tokens=%s)"
    (stop_reason_label resp.stop_reason)
    (List.length resp.content)
    shape.Agent_sdk.Response_shape.text_blocks
    shape.Agent_sdk.Response_shape.text_chars
    thinking.Keeper_hooks_oas_types.thinking_kind
    thinking.Keeper_hooks_oas_types.thinking_blocks
    thinking.Keeper_hooks_oas_types.thinking_chars
    thinking.Keeper_hooks_oas_types.redacted_thinking_blocks
    shape.Agent_sdk.Response_shape.tool_use_count
    shape.Agent_sdk.Response_shape.tool_result_count
    shape.Agent_sdk.Response_shape.image_count
    shape.Agent_sdk.Response_shape.document_count
    shape.Agent_sdk.Response_shape.audio_count
    input_tokens
    output_tokens

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

let panel_failure_code (failure : Fusion_types.panel_failure) : string =
  match failure with
  | Fusion_types.Timeout -> "timeout"
  | Fusion_types.Bridge_error _ -> "bridge_error"
  | Fusion_types.Provider_error _ -> "provider_error"
  | Fusion_types.Invalid_structured_response _ -> "invalid_structured_response"
  | Fusion_types.Empty_response _ -> "empty_response"
  | Fusion_types.Invalid_max_output_tokens _ -> "invalid_max_output_tokens"

let panel_failure_detail ~runtime_id (failure : Fusion_types.panel_failure) : string =
  match failure with
  | Fusion_types.Timeout -> "timeout"
  | Fusion_types.Bridge_error detail -> Printf.sprintf "Bridge error: %s" detail
  | Fusion_types.Provider_error detail -> provider_error_detail ~runtime_id detail
  | Fusion_types.Invalid_structured_response detail -> detail
  | Fusion_types.Empty_response detail -> detail
  | Fusion_types.Invalid_max_output_tokens n ->
    Printf.sprintf "invalid max_output_tokens %d" n

(* 이미 attribution된 실패를 재-attribution 없이 렌더한다. Provider_error의 detail은
   실패 시점(panel outcome_of_result / build_agent)에 provider_error_detail
   ~runtime_id:model(raw)로 정규화돼 있으므로, sink가 다시 runtime_id를 입히면
   panelist(정체성, 예 "skeptic (claude)")가 "Provider '...'" 슬롯에 새거나 중복
   prefix가 붙는다 (RFC-0278). panelist는 panel_answer.model/failed_model에만 두고
   provider attribution은 detail 안에 이미 박혀 있는 raw model을 쓴다. *)
let panel_failure_text (failure : Fusion_types.panel_failure) : string =
  match failure with
  | Fusion_types.Timeout -> "timeout"
  | Fusion_types.Bridge_error detail -> Printf.sprintf "Bridge error: %s" detail
  | Fusion_types.Provider_error detail -> detail
  | Fusion_types.Invalid_structured_response detail -> detail
  | Fusion_types.Empty_response detail -> detail
  | Fusion_types.Invalid_max_output_tokens n ->
    Printf.sprintf "invalid max_output_tokens %d" n

let timeout_budget_opt timeout_s =
  if Float.is_finite timeout_s && timeout_s > 0.0 then Some timeout_s else None

let apply_timeout_budget ?timeout_s (base_config : Runtime_agent.config) =
  match Option.bind timeout_s timeout_budget_opt with
  | None -> base_config
  | Some timeout_s ->
    (* Fusion owns the structural wall-clock budget via the outer
       Masc_oas_bridge.run_safe call. *)
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

let build_agent
    ~sw
    ~net
    ~system_prompt
    ?(tools = [])
    ?timeout_s
    ?name
    ?provider_config_transform
    (model : string)
  : (Agent_sdk.Agent.t, Fusion_types.panel_failure) result
  =
  (* 카드명(Async_agent.all이 결과 키로 반환)은 패널 정체성([name], 예 "skeptic (claude)").
     provider 라우팅·에러 귀속은 원 [model]로 따로 한다 — 정체성과 routable model을 한
     문자열에 압축하지 않는다 (RFC-0278). [name] 미지정(judge·label 없는 panel)이면 카드명=model.
     default=[model]은 외부 파싱된 unknown 입력의 편의적 추측이 아니라 byte-identity
     계약(label 없으면 정체성=model)인 total mapping이라 sound-partial. DET-OK *)
  let card_name = Option.value name ~default:model in
  match Runtime_oas_runner.resolve_runtime_providers ~runtime_id:model () with
  | Error e ->
    Error ((Fusion_types.Provider_error e : Fusion_types.panel_failure))
  | Ok [] ->
    Error
      ((Fusion_types.Provider_error (model ^ ": no provider config")
        : Fusion_types.panel_failure))
  | Ok (provider_cfg :: _) ->
    let provider_cfg : (Llm_provider.Provider_config.t, Fusion_types.panel_failure) result =
      match provider_config_transform with
      | None -> Ok provider_cfg
      | Some transform ->
        Result.map_error
          (fun detail ->
             ( Fusion_types.Provider_error (provider_error_detail ~runtime_id:model detail)
               : Fusion_types.panel_failure ))
          (transform provider_cfg)
    in
    (* v1: runtime이 여러 provider를 주면 첫 번째만(단일 provider 가정). *)
    (match provider_cfg with
     | Error _ as err -> err
     | Ok provider_cfg ->
       let base_config =
         Runtime_agent.default_config
           ~name:card_name
           ~provider_cfg
           ~system_prompt
           ~tools
       in
       let config = apply_timeout_budget ?timeout_s base_config in
       (match Runtime_agent.build ~sw ~net ~config with
        | Ok agent -> Ok agent
        | Error e ->
          Error
            ((Fusion_types.Provider_error
                (provider_error_detail
                   ~runtime_id:model
                   (Agent_sdk.Error.to_string e))
              : Fusion_types.panel_failure))))

module For_testing = struct
  let apply_timeout_budget = apply_timeout_budget
  let empty_response_detail = empty_response_detail
end
