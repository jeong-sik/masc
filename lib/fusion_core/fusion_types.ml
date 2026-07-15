(* Fusion — 패널+심판 심의 루프의 타입드 계약 (구현).
   계약/문서: fusion_types.mli, docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md *)

type usage =
  { input_tokens : int
  ; output_tokens : int
  }
[@@deriving yojson, show, eq]

let zero_usage = { input_tokens = 0; output_tokens = 0 }

let add_usage a b =
  { input_tokens = a.input_tokens + b.input_tokens
  ; output_tokens = a.output_tokens + b.output_tokens
  }

(* [Error] 분기의 usage를 모두 합산한다([Ok]는 무시). 전원 실패 같은 degrade 경로에서
   첫 에러의 usage만 전파하면 나머지 심판이 태운 토큰을 undercount하므로(적대 리뷰
   #22093 all-fail), 실패분 usage를 fold해 총 소비를 보존한다. *)
let sum_error_usage results =
  List.fold_left
    (fun acc (_, r) ->
      match r with
      | Error (_, u) -> add_usage acc u
      | Ok _ -> acc)
    zero_usage results

(* [first_error_message]는 results에서 첫 [Error]의 메시지를 추출한다(usage는 버림).
   all-fail 분기의 대표 메시지 선정용. *)
let first_error_message results =
  List.find_map
    (fun (_, r) -> match r with Error (msg, _) -> Some msg | Ok _ -> None)
    results

(* [all_fail_error ~fallback results]는 전원 실패(degrade) 경로의 회계를 한 번에 계산한다:
   [sum_error_usage]로 모든 실패 usage를 합산하고, 첫 [Error] 메시지를 대표로 결합한다.
   [Error]가 하나도 없으면(도달 불가 분기) [fallback]을 합산 usage(빈이면 zero)와 묶는다.
   분리 전엔 fusion_orchestrator [] 분기에 인라인이라 회계 wiring(합산 usage가 Error에 실리는가,
   첫 메시지가 대표로 pick되는가)을 단위 테스트할 수 없었는데(적대 리뷰 #22099 P2),
   다형적 순수 함수로 빼내어 firsts만으로 검증한다. *)
let all_fail_error ~fallback results =
  let failed_usage = sum_error_usage results in
  let msg = match first_error_message results with Some m -> m | None -> fallback in
  (msg, failed_usage)

(* [Ok]·[Error] 양 분기의 usage를 모두 합산한다. 일부 성공/일부 실패한 fan-out(JOJ
   1차 심판 등)이 태운 *모든* 토큰을 보존한다. [sum_error_usage](실패분만)와 의도가
   구분된다 — 이쪽은 "실행된 전부", 저쪽은 "실패한 것만". 부분-실패 경로에서
   성공분 fold + 실패분 fold를 따로 더하는 대신 한 번에 합산한다(적대 리뷰 #22134). *)
let sum_all_usage results =
  List.fold_left
    (fun acc (_, r) ->
      match r with
      | Ok (_, u) | Error (_, u) -> add_usage acc u)
    zero_usage results

module Fusion_depth = struct
  type t =
    | Top
    | Nested
  [@@deriving yojson, show, eq]
end

type panel_failure =
  | Timeout
  | Bridge_error of string
  | Provider_error of string
  | Invalid_structured_response of string
  | Empty_response of string
  | Invalid_max_output_tokens of int
[@@deriving to_yojson, show, eq]

let panel_failure_of_yojson = function
  | `String "Timeout" -> Ok Timeout
  | `String "Empty_response" -> Ok (Empty_response "empty response")
  | `List [ `String "Timeout" ] -> Ok Timeout
  | `List [ `String "Provider_error"; `String detail ] -> Ok (Provider_error detail)
  | `List [ `String "Invalid_structured_response"; `String detail ] ->
    Ok (Invalid_structured_response detail)
  | `List [ `String "Empty_response"; `String detail ] -> Ok (Empty_response detail)
  | `List [ `String "Invalid_max_output_tokens"; `Int value ] ->
    Ok (Invalid_max_output_tokens value)
  | json ->
    Error
      (Printf.sprintf
         "Fusion_types.panel_failure_of_yojson: unsupported shape %s"
         (Yojson.Safe.to_string json))

type panel_answer =
  { model : string
  ; answer : string
  ; usage : usage
  }
[@@deriving yojson, show, eq]

type panel_error =
  { failed_model : string
  ; reason : panel_failure
  }
[@@deriving yojson, show, eq]

type panel_outcome =
  | Answered of panel_answer
  | Failed of panel_error
[@@deriving yojson, show, eq]

let answered_of outcomes =
  List.filter_map
    (function Answered a -> Some a | Failed _ -> None)
    outcomes

type skip_reason =
  | No_panel_answers of { total : int }
[@@deriving yojson, show, eq]

let render_skip_reason = function
  | No_panel_answers { total } ->
    Printf.sprintf "fusion aborted: none of %d panels returned an answer" total

let no_panel_answers_error =
  "all panels failed: no answered panel to synthesize"

type claim =
  { text : string
  ; supporting_models : string list
  }
[@@deriving yojson, show, eq]

type contradiction =
  { topic : string
  ; positions : (string * string) list
  ; evidence : string list
  }
[@@deriving yojson, show, eq]

type coverage_gap =
  { gap_topic : string
  ; addressed_by : string list
  ; missing : string option  (** 무엇이 빠졌는지. 미상이면 None (""로 압축하지 않음). *)
  }
[@@deriving yojson, show, eq]

type insight =
  { insight_text : string
  ; from_model : string
  }
[@@deriving yojson, show, eq]

type recommendation =
  { action : string
  ; rationale : string
  }
[@@deriving yojson, show, eq]

type insufficiency = { missing_for_decision : string list }
[@@deriving yojson, show, eq]

type judge_decision =
  | Answer of string
  | Recommend of recommendation
  | Insufficient of insufficiency
[@@deriving yojson, show, eq]

type judge_synthesis =
  { consensus : claim list
  ; contradictions : contradiction list
  ; partial_coverage : coverage_gap list
  ; unique_insights : insight list
  ; blind_spots : string list
  ; resolved_answer : string
  ; decision : judge_decision
  }
[@@deriving yojson, show, eq]

(* 심판 실행 관측 record (RFC-0284). [panel_outcome]와 구조 동형 — 실제로 실행된 심판
   노드를 *사후* record로 보존한다. JOJ의 N개 1차 심판 + meta가 orchestrator 내부에서만
   존재하다 [Result.map fst]로 소실되던 것을, 패널처럼 배열로 board 증거에 남긴다.
   이것은 *관측 데이터*(무엇이 실행됐나)이지 *실행 추상*(어떻게 조립하나 — purge된
   ChainEngine node-graph DSL)이 아니다: 대시보드는 위상 이름 없이 이 배열의 shape만으로
   구조를 렌더한다(1=simple, 2=refine, N+meta=judge-of-judges,
   grouped firsts+stage_meta+final_meta=staged judge-of-judges). 콤비네이터/그래프 어휘는
   도입하지 않는다(RFC-0284 §4). *)
type judge_role =
  | Single  (** Simple 위상의 단일 심판. *)
  | Refine_pass  (** Refine/Conditional의 2차(재검토) 심판. *)
  | First of string  (** JOJ 1차 심판. panelist_id를 정체성으로 보존(panel model과 대칭). *)
  | Meta  (** JOJ meta(reconcile) 심판. *)
  | Stage_meta of int  (** staged JOJ의 stage reducer. 정체성은 ["stage-N"]. *)
  | Final_meta  (** staged JOJ의 최종 reducer. *)
[@@deriving yojson, show, eq]

type judge_node =
  { role : judge_role
  ; synthesis : judge_synthesis
  ; usage : usage
  }
[@@deriving yojson, show, eq]

(* 심판(judge) 실패의 닫힌 합. {!panel_failure}와 동형이되 심판 도메인 전용 사유
   ([Empty_result]/[Build_error]/[Parse_error])를 추가한다.
   [Fusion_judge] 계열이 {!Agent_sdk.Error}의 [Timeout] variant를 match에서 잡아 typed로
   반환하므로, 호출자는 string substring 분류 없이 exhaustive match로 분류한다
   (CLAUDE.md §string-classifier 안티패턴 회피). [panel_failure]를 공유하지 않는 이유는
   mli 주석 참조. *)
type judge_failure =
  | Timeout
  | Provider_error of string
  | Empty_response of string
  | Empty_result
  | Build_error of string
  | Parse_error of string
  | Panels_unavailable of skip_reason
  | Internal_error of string
[@@deriving yojson, show, eq]

let judge_failure_is_timeout = function Timeout -> true | _ -> false

let judge_failure_text = function
  | Timeout -> "timeout"
  | Provider_error detail -> detail
  | Empty_response detail -> detail
  | Empty_result -> "judge: empty result"
  | Build_error detail -> detail
  | Parse_error detail -> detail
  | Panels_unavailable reason -> render_skip_reason reason
  | Internal_error detail -> detail

let judge_failure_tag = function
  | Timeout -> "timeout"
  | Provider_error _ -> "provider_error"
  | Empty_response _ -> "empty_response"
  | Empty_result -> "empty_result"
  | Build_error _ -> "build_error"
  | Parse_error _ -> "parse_error"
  | Panels_unavailable _ -> "panels_unavailable"
  | Internal_error _ -> "internal_error"

type judge_error_node =
  { failed_role : judge_role
  ; failure : judge_failure
  ; usage : usage
      (** 실패해도 태운 토큰 — 관측 record가 비용을 버리지 않는다(RFC-0284, 적대 리뷰 #22112 E).
          [panel_error]와 달리 심판 실패는 토큰 소비 후일 수 있어 usage를 동반한다. *)
  ; elapsed_s : float
      (** 이 심판 노드가 시작된 시점부터 실패까지 경과한 시간(초). 예산/타임아웃
          분석에 쓰인다(RFC-0284-FUSION-P0). [timed_out]은 [judge_failure_is_timeout failure]
          로 파생 가능해 별도 필드에서 제거했다. *)
  }
[@@deriving yojson, show, eq]

(* 심판 한 명의 실행 결과 — 성공 또는 격리된 실패. [panel_outcome] (Answered/Failed)와
   구조 동형이라 sink/대시보드가 패널과 같은 배열 렌더 경로를 재사용한다. *)
type judge_outcome =
  | Synthesized of judge_node  (** panel [Answered] 대칭. *)
  | Judge_failed of judge_error_node  (** panel [Failed] 대칭. *)
[@@deriving yojson, show, eq]

type fusion_trigger =
  | Explicit_tool_call
  | Low_confidence
  | High_stakes of string
  | Contested_board of string
  | Operator_requested
  | Harness_eval
[@@deriving yojson, show, eq]

let trigger_label = function
  | Explicit_tool_call -> "explicit_tool_call"
  | Low_confidence -> "low_confidence"
  | High_stakes _ -> "high_stakes"
  | Contested_board _ -> "contested_board"
  | Operator_requested -> "operator_requested"
  | Harness_eval -> "harness_eval"

type fusion_request =
  { run_id : string
  ; keeper : string
  ; prompt : string
  ; preset : string
  ; web_tools : bool
  ; depth : Fusion_depth.t
  ; trigger : fusion_trigger
  }
[@@deriving yojson, show, eq]

type deny_reason =
  | Disabled
  | Preset_unknown of string
  | Depth_exceeded
[@@deriving yojson, show, eq]

let deny_reason_label = function
  | Disabled -> "disabled"
  | Preset_unknown _ -> "preset_unknown"
  | Depth_exceeded -> "depth_exceeded"

type gate_decision =
  | Allow of fusion_request
  | Deny of deny_reason
[@@deriving yojson, show, eq]

(* 심의 위상(topology) — 패널 답을 어떤 합성 구조로 reduce할지. 닫힌 합:
   keeper는 masc_fusion 도구에서 이름으로 고르고, 게이트는 보지 않으며, 오케스트레이터가
   이 변형으로 dispatch한다. 그래프 datatype이 아니라 named composition의 닫힌 집합
   (RFC-0252 §13 P2 확장; "Fusion as a Tool"의 합성-by-selection). 새 위상은 여기 추가하면
   orchestrator dispatch가 exhaustive-match 컴파일 에러로 누락을 강제한다. *)
type fusion_topology =
  | Simple  (** panel → judge → sink (현행, byte-identical) *)
  | Refine  (** panel → judge → judge'(1차 종합을 재검토) → sink *)
  | Conditional
      (** panel → judge → (1차 판정이 [Insufficient]일 때만) judge'(refine) → sink.
          애매할 때만 한 단계 더 깊이; 그 외엔 1차 종합 그대로. *)
  | Judge_of_judges
      (** panel → [N개 1차 심판] → meta-judge → sink (RFC-0283). 서로 다른 N개 1차
          심판이 같은 패널을 독립 종합하고, meta가 reconcile. preset.judges >= 2 필요. *)
  | Staged_judge_of_judges
      (** panel → [N개 1차 심판] → fixed-size stage meta reducers → final meta reducer
          → sink. preset.judges count must form at least two exact groups of
          TOML key [staged_judge_group_size]. This is a named topology,
          not recursive fusion; [Fusion_depth.Nested] remains denied. *)
[@@deriving yojson, show, eq]

let fusion_topology_to_string = function
  | Simple -> "simple"
  | Refine -> "refine"
  | Conditional -> "conditional"
  | Judge_of_judges -> "judge_of_judges"
  | Staged_judge_of_judges -> "staged_judge_of_judges"

(* [to_string]의 역함수, 닫힌 합 밖은 [None]=fail-closed (Unknown→permissive 회피).
   keeper 입력 문자열을 typed 위상으로 parse한 뒤 exhaustive match하게 한다. round-trip은
   [test/fusion_core/test_fusion.ml :: fusion_topology_roundtrip]가 핀. *)
let fusion_topology_of_string = function
  | "simple" -> Some Simple
  | "refine" -> Some Refine
  | "conditional" -> Some Conditional
  | "judge_of_judges" -> Some Judge_of_judges
  | "staged_judge_of_judges" -> Some Staged_judge_of_judges
  | _ -> None

let all_fusion_topologies : fusion_topology list =
  [ Simple; Refine; Conditional; Judge_of_judges; Staged_judge_of_judges ]

let all_fusion_topology_strings : string list =
  List.map fusion_topology_to_string all_fusion_topologies

(* Conditional 위상의 에스컬레이트 정책: 1차 심판 판정이 더 깊은 심의를 요하는가.
   [Insufficient](패널이 결정에 부족 = 애매)면 escalate, [Answer]/[Recommend](결론 있음)이면
   1차 종합 유지. 닫힌 합 exhaustive match(catch-all 없음) — 새 decision 변형 추가 시 여기서
   컴파일 에러로 escalate 정책을 명시 갱신하게 강제한다. confidence "축"을 새로 만들어 역분류하지
   않고(reverse-classifier 회피) 기존 닫힌 합을 직접 본다. 순수 — 테스트 가능. *)
let decision_warrants_escalation = function
  | Insufficient _ -> true
  | Answer _ | Recommend _ -> false

(* 1차 심판 종합을 refine 심판 프롬프트에 실어 보낼 lossless 텍스트 렌더. judge_synthesis의
   7필드 + 닫힌 합 decision을 모두 보존한다(CLAUDE.md 워크어라운드 #2 "두 개념을 한 string
   채널에 압축" 회피 — resolved_answer 한 줄로 collapse하지 않는다). 빈 리스트는 "(none)"으로
   렌더해 구조를 항상 노출(테스트 가능). decision은 닫힌 합 exhaustive match라 새 변형 추가 시
   컴파일 에러로 갱신을 강제한다. 순수 — 테스트 가능. *)
let render_prior_synthesis (s : judge_synthesis) : string =
  let bullets to_line = function
    | [] -> "(none)"
    | xs -> String.concat "\n" (List.map (fun x -> "- " ^ to_line x) xs)
  in
  let consensus =
    bullets
      (fun (c : claim) ->
        Printf.sprintf "%s (supported by: %s)" c.text
          (String.concat ", " c.supporting_models))
      s.consensus
  in
  let contradictions =
    bullets
      (fun (c : contradiction) ->
        let positions =
          c.positions
          |> List.map (fun (model, stance) ->
                 Printf.sprintf "%s says \"%s\"" model stance)
          |> String.concat "; "
        in
        Printf.sprintf "%s: %s [evidence: %s]" c.topic positions
          (String.concat "; " c.evidence))
      s.contradictions
  in
  let partial_coverage =
    bullets
      (fun (g : coverage_gap) ->
        Printf.sprintf "%s (addressed by: %s; missing: %s)" g.gap_topic
          (String.concat ", " g.addressed_by)
          (match g.missing with Some m -> m | None -> "unspecified"))
      s.partial_coverage
  in
  let unique_insights =
    bullets
      (fun (i : insight) ->
        Printf.sprintf "%s (from: %s)" i.insight_text i.from_model)
      s.unique_insights
  in
  let blind_spots = bullets (fun (b : string) -> b) s.blind_spots in
  let decision =
    match s.decision with
    | Answer text -> Printf.sprintf "Answer: %s" text
    | Recommend r -> Printf.sprintf "Recommend action \"%s\" — %s" r.action r.rationale
    | Insufficient i ->
      Printf.sprintf "Insufficient — missing: %s"
        (String.concat "; " i.missing_for_decision)
  in
  Printf.sprintf
    {|CONSENSUS:
%s
CONTRADICTIONS:
%s
PARTIAL COVERAGE:
%s
UNIQUE INSIGHTS:
%s
BLIND SPOTS:
%s
RESOLVED ANSWER:
%s
DECISION: %s|}
    consensus contradictions partial_coverage unique_insights blind_spots
    s.resolved_answer decision
