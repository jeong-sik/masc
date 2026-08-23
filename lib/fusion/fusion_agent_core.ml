(* Fusion — AGENT_CORE 호출 공유 글루 (구현).
   계약/문서: fusion_agent_core.mli, docs/rfc/RFC-0252 §7

   AGENT_CORE 범용 함수만 소비: Runtime_agent_core_runner(id→provider) → Runtime_agent(build).
   fusion 개념은 AGENT_CORE에 노출하지 않는다. *)

let answer_text (resp : Agent_core.Types.api_response) : string =
  Agent_core.Types.visible_text_of_response resp

let stop_reason_label = Keeper_hooks_agent_core_types.stop_reason_to_label

(* 콘텐츠 블록 카운팅은 AGENT_CORE canonical projection
   [Agent_core.Response_shape.summarize_blocks]에 위임한다. 로컬 fold를 재구현하지 않는다
   (keeper_hooks_agent_core_types.ml의 F2 canonical projection 원칙과 동일 — 미이행 사이트였다).
   thinking_kind 분류만 MASC가 소유한다: AGENT_CORE는 model-family thinking 의미를 의도적으로
   노출하지 않으므로 [summarize_thinking_blocks]로 별도 산출한다. *)
let empty_response_detail (resp : Agent_core.Types.api_response) : string =
  let shape = Agent_core.Response_shape.summarize_blocks resp.content in
  let thinking = Keeper_hooks_agent_core_types.summarize_thinking_blocks resp.content in
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
    shape.Agent_core.Response_shape.text_blocks
    shape.Agent_core.Response_shape.text_chars
    thinking.Keeper_hooks_agent_core_types.thinking_kind
    thinking.Keeper_hooks_agent_core_types.thinking_blocks
    thinking.Keeper_hooks_agent_core_types.thinking_chars
    thinking.Keeper_hooks_agent_core_types.redacted_thinking_blocks
    shape.Agent_core.Response_shape.tool_use_count
    shape.Agent_core.Response_shape.tool_result_count
    shape.Agent_core.Response_shape.image_count
    shape.Agent_core.Response_shape.document_count
    shape.Agent_core.Response_shape.audio_count
    input_tokens
    output_tokens

let usage_of (resp : Agent_core.Types.api_response) : Fusion_types.usage =
  match resp.usage with
  | Some u ->
    { Fusion_types.input_tokens = u.Agent_core.Types.input_tokens
    ; output_tokens = u.Agent_core.Types.output_tokens
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
  | Fusion_types.Invalid_timeout_s _ -> "invalid_timeout_s"

let panel_failure_detail ~runtime_id (failure : Fusion_types.panel_failure) : string =
  match failure with
  | Fusion_types.Timeout -> "timeout"
  | Fusion_types.Bridge_error detail -> Printf.sprintf "Bridge error: %s" detail
  | Fusion_types.Provider_error detail -> provider_error_detail ~runtime_id detail
  | Fusion_types.Invalid_structured_response detail -> detail
  | Fusion_types.Empty_response detail -> detail
  | Fusion_types.Invalid_max_output_tokens n ->
    Printf.sprintf "invalid max_output_tokens %d" n
  | Fusion_types.Invalid_timeout_s s -> Printf.sprintf "invalid timeout_s %g" s

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
  | Fusion_types.Invalid_timeout_s s -> Printf.sprintf "invalid timeout_s %g" s

(** [Keeper_tool_descriptor]에서 날것의 web tool descriptor를 찾아
    [Agent_core.Tool.t]로 변환한다. 패널/심판이 web_search/web_fetch를
    호출할 수 있게 하는 목적으로만 쓰인다. *)
let agent_core_tool_of_descriptor (d : Keeper_tool_descriptor.t) : Agent_core.Tool.t option =
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
    (Tool_bridge.agent_core_tool_of_masc
       ~name:d.internal_name
       ~description:d.description
       ~input_schema:d.input_schema
       handler)

let web_tool_bundle () : Agent_core.Tool.t list =
  [ "masc_web_search"; "masc_web_fetch" ]
  |> List.map Keeper_tool_descriptor.descriptors_for_internal
  |> List.concat
  |> List.filter_map agent_core_tool_of_descriptor

(* AGENT_CORE 는 데드라인을 요청받으면 그것을 강제할 clock 도 함께 요구한다:
   [body_timeout_s] 만 주고 clock 을 빼면 요청이 dispatch 전에
   "body_timeout_s was supplied without the clock required to enforce it" 로
   거부된다(http_client.ml). 즉 preset 데드라인을 켜는 순간 clock 전달은 선택이
   아니라 같은 계약의 반쪽이다 — 이 함수가 그 반쪽을 한 곳에서 공급한다.

   clock 이 없으면 [None] 을 돌려주고 호출자는 데드라인 없이 진행한다. Eio 런타임
   위에서 도는 정상 경로에는 항상 clock 이 있고, 없다면 그건 데드라인을 못 지키는
   상황이지 패널을 전멸시킬 이유는 아니다(그 경우 provider 기본 데드라인이 남는다). *)
let deadline_clock () =
  match Masc_eio_env.get_opt () with
  | Some { Masc_eio_env.clock; _ } -> Some clock
  | None -> None

let build_agent
    ~sw
    ~net
    ~system_prompt
    ?(tools = [])
    ?max_tokens
    ?timeout_s
    ?name
    ?provider_config_transform
    (model : string)
  : (Agent_core.Agent.t, Fusion_types.panel_failure) result
  =
  (* 카드명(Async_agent.all이 결과 키로 반환)은 패널 정체성([name], 예 "skeptic (claude)").
     provider 라우팅·에러 귀속은 원 [model]로 따로 한다 — 정체성과 routable model을 한
     문자열에 압축하지 않는다 (RFC-0278). [name] 미지정(judge·label 없는 panel)이면 카드명=model.
     default=[model]은 외부 파싱된 unknown 입력의 편의적 추측이 아니라 byte-identity
     계약(label 없으면 정체성=model)인 total mapping이라 sound-partial. DET-OK *)
  let card_name = Option.value name ~default:model in
  (* ..._for_turn, not the bare binding: a panel dispatches like a keeper turn,
     so it needs the runtime's inference seed on top. Without it enable_thinking
     stays None, Backend_ollama omits the wire [think] field, and the model's
     chat template decides — thinking-on for reasoning models. The capability
     probe made the same omission and scored ollama.agentworld-35b-a3b 0/12 on
     tool calls it had made every time (#28529, #28473). *)
  match
    Runtime_agent_core_runner.resolve_runtime_providers_for_turn
      ~runtime_id:model
      ()
  with
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
       let config =
         match max_tokens with
         | None -> Ok base_config
         | Some n when Fusion_policy.valid_max_output_tokens (Some n) ->
           Ok { base_config with max_tokens = Some n }
         | Some n -> Error (Fusion_types.Invalid_max_output_tokens n)
       in
       (* preset 데드라인은 [Runtime_agent.config.body_timeout_s]로 집행한다 —
          AGENT_CORE가 이미 소유한 손잡이이며(Builder.with_body_timeout →
          Complete.complete 비스트리밍 총 왕복 cap), provider의
          [connect_timeout_s]와 달리 이름이 하는 일과 일치한다. provider config를
          변형하지 않으므로 같은 런타임을 쓰는 다른 소비자(키퍼 턴 등)의 예산은
          그대로다: override의 blast radius가 이 fusion 요청으로 한정된다.
          [None]이면 base_config를 그대로 둬 런타임/provider 선언이 유일한 값으로
          남는다. 유효성은 policy가 로드 시 이미 판정했지만, 직접 호출도 있으므로
          여기서도 닫아 잘못된 데드라인이 조용히 무시되지 않게 한다. *)
       let config =
         match config, timeout_s with
         | (Error _ as err), _ -> err
         | Ok config, None -> Ok config
         | Ok config, Some s when Fusion_policy.valid_timeout_s (Some s) ->
           Ok { config with body_timeout_s = Some s }
         | Ok _, Some s -> Error (Fusion_types.Invalid_timeout_s s)
       in
       match config with
       | Error _ as err -> err
       | Ok config ->
         (match Runtime_agent.build ~sw ~net ~config with
           | Ok agent -> Ok agent
           | Error e ->
             Error
               ((Fusion_types.Provider_error
                   (provider_error_detail
                      ~runtime_id:model
                      (Agent_core.Error.to_string e))
                 : Fusion_types.panel_failure))))

module For_testing = struct
  let empty_response_detail = empty_response_detail
end
