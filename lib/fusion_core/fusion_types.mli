(** Fusion — 패널+심판(panel+judge) 심의 루프의 타입드 계약.

    OpenRouter Fusion 스타일 심의를 MASC 안에서 구현하기 위한 닫힌 합(closed-sum)
    데이터 모델. 모든 분기는 catch-all(`_`) 없이 명시되어, 새 변형 추가 시
    컴파일러가 누락 사이트를 강제로 드러낸다 (CLAUDE.md §FSM Sparse Match 회피).

    이 모듈은 순수 데이터 타입만 담는다: OAS·키퍼·보드 의존 0, 독립 컴파일 가능.
    fan-out(패널), 구조화 출력(심판), 게이트, 가시성은 별도 모듈이 이 타입을 소비한다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md

    @stability Evolving *)

(** {1 토큰 사용량} *)

(** 단일 완성의 토큰 사용량. fusion은 패널 N + 심판 1 완성을 합산해 비용을
    회계한다 (RFC-0252 §10). 외부 usage 타입에 결합하지 않도록 자체 정의한다. *)
type usage =
  { input_tokens : int
  ; output_tokens : int
  }
[@@deriving yojson, show, eq]

(** 빈 사용량 (실패한 패널 등). *)
val zero_usage : usage

(** 두 사용량의 합 (패널 N + 심판 회계용). *)
val add_usage : usage -> usage -> usage

(** [sum_error_usage results]는 [results]의 [Error] 원소가 소비한 usage를 모두 합산한다
    ([Ok]은 무시). 전원 실패 등 degrade 경로에서 첫 에러의 usage만 전파해 나머지 심판이
    태운 토큰을 잃는 undercount를 막는다(적대 리뷰 #22093 all-fail). *)
val sum_error_usage : ('id * ('ok, 'msg * usage) result) list -> usage

(** [first_error_message results]는 results의 첫 [Error] 메시지를 추출한다(usage는 버림).
    [Error]가 없으면 [None]. all-fail 분기의 대표 메시지 선정용. *)
val first_error_message : ('id * ('ok, 'msg * usage) result) list -> 'msg option

(** [all_fail_error ~fallback results]는 전원 실패 경로의 회계를 한 번에 계산한다:
    [sum_error_usage]로 실패 usage를 합산하고 첫 [Error] 메시지를 대표로 묶는다.
    [Error]가 없으면(도달 불가) [fallback]과 합산 usage(빈이면 zero)를 묶는다
    (적대 리뷰 #22099 P2 — 인라인 회계 wiring을 순수 함수로 분리해 단위 테스트). *)
val all_fail_error :
  fallback:'msg -> ('id * ('ok, 'msg * usage) result) list -> 'msg * usage

(** [sum_all_usage results]는 [Ok]·[Error] 양 분기 usage를 모두 합산한다. 일부 성공/일부
    실패한 fan-out(JOJ 1차 심판 등)이 태운 *모든* 토큰을 보존한다. 성공분 fold와 실패분
    fold를 따로 더하던 부분-실패 경로를 단일 합산으로 단순화한다(적대 리뷰 #22134). *)
val sum_all_usage : ('id * ('a * usage, 'b * usage) result) list -> usage

(** {1 재귀 가드} *)

(** 심의 깊이. OpenRouter의 [x-openrouter-fusion-depth] 헤더에 대응하는 타입드
    가드. 패널/심판은 fusion을 다시 못 부른다 — 1단계로 제한 (RFC-0252 §10). *)
module Fusion_depth : sig
  type t =
    | Top  (** 키퍼/오퍼레이터가 시작한 최상위 심의 *)
    | Nested  (** 패널·심판 내부 — 더 내려갈 수 없음 *)
  [@@deriving yojson, show, eq]
end

(** {1 패널 결과} *)

(** 패널 한 명(한 모델)이 실패하는 방식. silent default 없이 명시된 닫힌 합
    (CLAUDE.md §Unknown→Permissive 회피). [Async_agent.all]이 per-agent 에러를
    격리하므로 한 패널 실패가 나머지를 죽이지 않는다. *)
type panel_failure =
  | Timeout  (** 구조적 타임아웃 (Masc_oas_bridge) *)
  | Bridge_error of string  (** MASC/OAS bridge bootstrap or wrapper error *)
  | Provider_error of string  (** provider/transport 에러, 메시지 보존 *)
  | Invalid_structured_response of string
      (** provider returned non-empty output that violated the requested panel
          answer JSON schema. *)
  | Empty_response of string
      (** 모델이 빈 응답. detail에는 stop_reason/usage/content shape만 보존하고,
          reasoning/thinking 본문은 노출하지 않는다. *)
  | Invalid_max_output_tokens of int
      (** Runtime defense-in-depth: output token override must be positive. *)
[@@deriving to_yojson, show, eq]

val panel_failure_of_yojson : Yojson.Safe.t -> (panel_failure, string) result
(** Accepts the current ppx-style tagged-list encoding and the legacy bare
    string encodings for [Timeout] / [Empty_response]. *)

(** 성공한 패널 한 명의 답. (variant inline record는 ppx_deriving_yojson 비호환이라
    named record로 분리한다.) *)
type panel_answer =
  { model : string
      (** 패널 정체성 (RFC-0278, {!Fusion_policy.panelist_id}): 라벨 없으면 provider
          model id, 라벨 있으면 ["label (model)"]. 심판/sink가 이 문자열로 패널을
          지칭한다. 라벨 없는(legacy/단일-occurrence) 패널은 = provider model. *)
  ; answer : string
  ; usage : usage
  }
[@@deriving yojson, show, eq]

(** 실패한 패널 한 명. *)
type panel_error =
  { failed_model : string  (** 패널 정체성 (panel_answer.model과 동일 의미). *)
  ; reason : panel_failure
  }
[@@deriving yojson, show, eq]

(** 패널 한 명의 결과 — 성공 또는 격리된 실패. *)
type panel_outcome =
  | Answered of panel_answer
  | Failed of panel_error
[@@deriving yojson, show, eq]

(** 성공한 답만 추출 (심판 입력 구성용). 입력 순서 보존. *)
val answered_of : panel_outcome list -> panel_answer list

(** 심판을 실행하지 않는 typed 사유. *)
type skip_reason =
  | No_panel_answers of { total : int }
[@@deriving yojson, show, eq]

val render_skip_reason : skip_reason -> string
(** Operator/log boundary renderer for {!skip_reason}. *)

val no_panel_answers_error : string
(** Legacy canonical string for callers that still need the pre-quorum
    all-panel-failed message. New code should use {!skip_reason}. *)

(** {1 심판 구조화 출력}

    [Structured.extract]의 provider-native JSON schema로 강제 파싱되는 닫힌 타입.
    surface-string 분류기가 아니다 (CLAUDE.md 워크어라운드 시그니처 #2 회피). *)

(** 패널 다수가 동의한 지점 — 높은 확신으로 취급. *)
type claim =
  { text : string
  ; supporting_models : string list
  }
[@@deriving yojson, show, eq]

(** 모델 간 불일치 — 입장(모델×stance)과 근거. *)
type contradiction =
  { topic : string
  ; positions : (string * string) list  (** (model, stance) *)
  ; evidence : string list
  }
[@@deriving yojson, show, eq]

(** 일부만 다룬 주제 — 누구는 다뤘으나 불완전. *)
type coverage_gap =
  { gap_topic : string
  ; addressed_by : string list
  ; missing : string option  (** 무엇이 빠졌는지. 미상이면 None. *)
  }
[@@deriving yojson, show, eq]

(** 한 모델만 낸 고유 통찰. *)
type insight =
  { insight_text : string
  ; from_model : string
  }
[@@deriving yojson, show, eq]

(** 심판이 권고하는 액션 (advisory — 키퍼가 평소대로 수행). *)
type recommendation =
  { action : string
  ; rationale : string
  }
[@@deriving yojson, show, eq]

(** 패널이 부족해 심의가 무효일 때 빠진 것. *)
type insufficiency = { missing_for_decision : string list }
[@@deriving yojson, show, eq]

(** 심판의 결정 — 닫힌 합. v1은 advisory(side-effect 없음). *)
type judge_decision =
  | Answer of string  (** resolved 텍스트 답 *)
  | Recommend of recommendation  (** 키퍼가 수행할 권고 *)
  | Insufficient of insufficiency  (** 심의 무효 *)
[@@deriving yojson, show, eq]

(** 심판의 구조화 종합 — OpenRouter Fusion의 5필드 + resolved + decision. *)
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

(** {1 심판 실행 관측 (RFC-0284)}

    실제로 실행된 심판 노드의 *사후* record. [panel_outcome]와 구조 동형이라 board
    증거/대시보드가 패널과 같은 배열 렌더 경로를 재사용한다. JOJ의 N개 1차 심판 + meta
    구조가 [Result.map fst] 평탄화로 소실되던 것을 보존한다. *관측 데이터*(무엇이
    실행됐나)이지 *실행 추상*(조립 DSL = purge된 ChainEngine)이 아니다. *)

(** 심판 노드의 위상 역할. [First]는 panelist_id를 정체성으로 보존. *)
type judge_role =
  | Single
  | Refine_pass
  | First of string
  | Meta
  | Stage_meta of int
  | Final_meta
[@@deriving yojson, show, eq]

(** 심판(judge) 한 명이 실패하는 방식. {!panel_failure}와 동형인 닫힌 합이되, 심판
    도메인에만 존재하는 사유([Empty_result]/[Build_error]/[Parse_error]/[Budget_exceeded])
    를 추가로 담는다. [panel_failure]를 literal하게 공유하지 않는 이유: 판(panel) 전용인
    [Invalid_max_output_tokens]가 심판에서 dead variant가 되고, wave-budget SKIP을
    [Provider_error "...skipped..."] 문자열에 숨기면 orchestrator의 fallback 분류가
    substring match로 잔존하기 때문이다(CLAUDE.md §string-classifier 안티패턴).

    근원에서 typed로 propagate한다: [Fusion_judge.run] 계열이 {!Agent_sdk.Error}의
    [Timeout] variant를 match에서 잡아 [Timeout]으로, provider/transport 에러를
    [Provider_error]로 반환한다. 호출자는 [string]을 역분류하지 않고 exhaustive match로
    분류한다. *)
type judge_failure =
  | Timeout  (** 구조적 타임아웃 — Agent_sdk.Error.Api (Retry.Timeout _)에서 propagate *)
  | Provider_error of string  (** provider/transport 에러, to_string 보존 *)
  | Empty_response of string  (** 모델이 빈 응답 *)
  | Empty_result  (** Async_agent.all 이 빈 결과를 반환 *)
  | Build_error of string  (** Fusion_oas.build_agent 실패 *)
  | Parse_error of string  (** Fusion_judge_parse.of_string 파싱 실패 *)
  | Budget_exceeded of string  (** wave budget 초과로 심판 실행 전 SKIP *)
  | Panels_unavailable of skip_reason
      (** 패널 정족수 미달로 심판이 실행조차 되지 않음. 2026-07-01 사고에서 이
          사유가 [Internal_error] 문자열로 압축돼 모든 keeper-가시 표면이 패널
          전멸을 "judge failed"로 오귀속했다 — 진단 주체(키퍼)가 judge 메커니즘을
          의심하게 만든 원인. typed로 분리해 failure_code/헤드라인이 패널 실패를
          패널 실패로 말하게 한다. *)
  | Internal_error of string  (** all_fail_error fallback / 미분류 *)
[@@deriving yojson, show, eq]

(** [Timeout] 변형인가. {!judge_error_node}의 [timed_out] 파생처럼, 분류는 variant 자체로
    충분하므로 별도 bool 필드를 두지 않는다. *)
val judge_failure_is_timeout : judge_failure -> bool

(** sink/로그용 사람-가독 문자열. {!Fusion_oas.panel_failure_text}와 대칭. *)
val judge_failure_text : judge_failure -> string

(** 대시보드 failure_code 키용 정규화 태그(timeout/provider_error/...). *)
val judge_failure_tag : judge_failure -> string

(** 성공한 심판 노드 — 역할 + 종합 + 노드별 실측 usage. *)
type judge_node =
  { role : judge_role
  ; synthesis : judge_synthesis
  ; usage : usage
  }
[@@deriving yojson, show, eq]

(** 격리된 심판 실패 노드. [failure]가 single source of truth: [timed_out]은
    [judge_failure_is_timeout failure]로 파생 가능해 별도 필드에서 제거했다. *)
type judge_error_node =
  { failed_role : judge_role
  ; failure : judge_failure
  ; usage : usage
      (** 실패해도 태운 토큰 — 관측 record가 비용을 버리지 않는다(RFC-0284, 적대 리뷰 #22112 E). *)
  ; elapsed_s : float
      (** Wave start부터 실패까지 경과한 시간(초). 타임아웃/예산 원인 분석용. *)
  }
[@@deriving yojson, show, eq]

(** 심판 한 명의 실행 결과 — [panel_outcome] (Answered/Failed)와 동형. *)
type judge_outcome =
  | Synthesized of judge_node
  | Judge_failed of judge_error_node
[@@deriving yojson, show, eq]

(** {1 트리거} *)

(** fusion 발동 사유 — 게이트 입력(이유 라벨). catch-all 없음.

    게이트는 trigger의 *종류*로 심의 가치를 판정하지 않는다(RFC-0252 §6).
    "이 결정이 심의할 가치가 있나"는 키퍼(이미 LLM)가 스스로 판단해 masc_fusion을
    호출하는 것으로 표현되고, 게이트는 구조적 안전(enabled/preset/depth)만 본다.
    따라서 각 변형은 score 비교·문자열 매칭 대상이 아니라 "왜 발동했나"를 기록하는
    라벨이다 (board meta·로그·메트릭용). *)
type fusion_trigger =
  | Explicit_tool_call  (** 키퍼가 masc_fusion을 직접 호출 *)
  | Low_confidence  (** 키퍼가 자기 답의 확신이 낮다고 *판단*해 요청 *)
  | High_stakes of string  (** 키퍼가 high-stakes로 판단한 task 설명 (라벨) *)
  | Contested_board of string  (** post_id — 보드에서 다툼 *)
  | Operator_requested
  | Harness_eval  (** eval 하네스가 결정론적으로 구동 *)
[@@deriving yojson, show, eq]

(** 안정적 짧은 라벨 (로깅·메트릭·board meta용). [show]의 장황한 출력 대신 사용. *)
val trigger_label : fusion_trigger -> string

(** {1 심의 요청} *)

(** out-of-band 오케스트레이터에 전달되는 심의 요청. *)
type fusion_request =
  { run_id : string  (** correlation: 패널 N + 심판 + board post를 하나로 묶음 *)
  ; keeper : string  (** 결과를 받을 키퍼 chat lane *)
  ; prompt : string
  ; preset : string  (** runtime.toml [fusion.presets.*] 이름 *)
  ; web_tools : bool
      (** web search/fetch 도구를 패널/심판에 주입할지 여부. preset을 오버라이드. *)
  ; depth : Fusion_depth.t
  ; trigger : fusion_trigger
  }
[@@deriving yojson, show, eq]

(** {1 게이트 결정} *)

(** 게이트가 심의를 거부하는 사유 — 닫힌 합. 발동 통제가 명시적·테스트 가능. *)
type deny_reason =
  | Disabled  (** [fusion].enabled = false *)
  | Preset_unknown of string  (** preset 이름이 config에 없음 (fail-fast) *)
  | Depth_exceeded  (** depth = Nested *)
[@@deriving yojson, show, eq]

(** 안정적 짧은 라벨 (로깅·메트릭용). *)
val deny_reason_label : deny_reason -> string

(** 게이트 출력 — 통과(요청 반환) 또는 거부(사유). *)
type gate_decision =
  | Allow of fusion_request
  | Deny of deny_reason
[@@deriving yojson, show, eq]

(** {1 심의 위상 (topology)}

    패널 답을 어떤 합성 구조로 reduce할지. 닫힌 합 — keeper가 [masc_fusion] 도구에서
    이름으로 고르고(합성-by-selection), 게이트는 보지 않으며, 오케스트레이터가 이 변형으로
    dispatch한다. 그래프 datatype이 아니라 named composition의 닫힌 집합(RFC-0252 §13 P2).
    새 위상은 여기 추가 시 orchestrator dispatch가 exhaustive-match로 누락을 강제한다. *)
type fusion_topology =
  | Simple  (** panel → judge → sink (현행, byte-identical) *)
  | Refine  (** panel → judge → judge'(1차 종합을 재검토) → sink *)
  | Conditional
      (** panel → judge → (1차 판정이 [Insufficient]일 때만) judge'(refine) → sink.
          애매할 때만 한 단계 더 깊이; 그 외엔 1차 종합 그대로(= Simple). *)
  | Judge_of_judges
      (** panel → [N개 1차 심판] → meta-judge → sink (RFC-0283). 서로 다른 N개 1차
          심판이 같은 패널을 독립 종합하고, meta가 reconcile. preset.judges >= 2 필요. *)
  | Staged_judge_of_judges
      (** panel → [N개 1차 심판] → fixed-size stage meta reducers → final meta reducer
          → sink. preset.judges count must form at least two exact groups of
          TOML key [staged_judge_group_size]. Named topology only; it does
          not relax the nested fusion depth guard. *)
[@@deriving yojson, show, eq]

(** 안정적 wire 문자열 ([masc_fusion] 도구 인자·로깅용). *)
val fusion_topology_to_string : fusion_topology -> string

(** [fusion_topology_to_string]의 역함수. 닫힌 합 밖은 [None]=fail-closed
    (Unknown→permissive default 회피). round-trip은
    [test/fusion_core/test_fusion.ml :: fusion_topology_roundtrip]가 핀. *)
val fusion_topology_of_string : string -> fusion_topology option

(** 모든 위상 (도구 스키마 설명·테스트 vocabulary). *)
val all_fusion_topologies : fusion_topology list

(** [all_fusion_topologies]의 wire 문자열 (도구 인자 허용값 목록). *)
val all_fusion_topology_strings : string list

(** [Conditional] 위상의 에스컬레이트 정책. 1차 심판 [decision]이 더 깊은 심의를 요하면
    [true]. v1: [Insufficient]만 [true]([Answer]/[Recommend]는 [false]). 닫힌 합
    exhaustive — 새 [judge_decision] 변형 추가 시 컴파일 에러로 정책 갱신을 강제한다. *)
val decision_warrants_escalation : judge_decision -> bool

(** 1차 심판 종합을 refine 심판 프롬프트에 실을 lossless 텍스트로 렌더한다.
    [judge_synthesis]의 7필드 + 닫힌 합 [decision]을 모두 보존한다(resolved_answer 한 줄로
    collapse하지 않음 — CLAUDE.md 워크어라운드 #2 회피). 빈 리스트는 "(none)". 순수. *)
val render_prior_synthesis : judge_synthesis -> string
