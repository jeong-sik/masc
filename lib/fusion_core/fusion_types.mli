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

(** {1 재귀 가드} *)

(** 심의 깊이. OpenRouter의 [x-openrouter-fusion-depth] 헤더에 대응하는 타입드
    가드. 패널/심판은 fusion을 다시 못 부른다 — 1단계로 제한 (RFC-0252 §10). *)
module Fusion_depth : sig
  type t =
    | Top  (** 키퍼/오퍼레이터가 시작한 최상위 심의 *)
    | Nested  (** 패널·심판 내부 — 더 내려갈 수 없음 *)
  [@@deriving yojson, show, eq]

  (** [descend Top = Some Nested]; [descend Nested = None].
      [None]은 "2단계 진입 거부"를 뜻한다. 게이트가 이를 [Depth_exceeded]로 변환. *)
  val descend : t -> t option

  val to_string : t -> string
end

(** {1 패널 결과} *)

(** 패널 한 명(한 모델)이 실패하는 방식. silent default 없이 명시된 닫힌 합
    (CLAUDE.md §Unknown→Permissive 회피). [Async_agent.all]이 per-agent 에러를
    격리하므로 한 패널 실패가 나머지를 죽이지 않는다. *)
type panel_failure =
  | Timeout  (** 구조적 타임아웃 (Masc_oas_bridge) *)
  | Provider_error of string  (** provider/transport 에러, 메시지 보존 *)
  | Empty_response  (** 모델이 빈 응답 (keeper_librarian 빈응답 전례) *)
  | Budget_exhausted  (** per-panel tool-call 예산 소진 *)
[@@deriving yojson, show, eq]

(** 성공한 패널 한 명의 답. (variant inline record는 ppx_deriving_yojson 비호환이라
    named record로 분리한다.) *)
type panel_answer =
  { model : string
  ; answer : string
  ; confidence : float option  (** 모델이 자기 확신도를 냈으면 *)
  ; usage : usage
  }
[@@deriving yojson, show, eq]

(** 실패한 패널 한 명. *)
type panel_error =
  { failed_model : string
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

(** {1 트리거} *)

(** [Low_confidence] 페이로드 (variant inline record 회피용 named record). *)
type low_confidence =
  { score : float
  ; threshold : float
  }
[@@deriving yojson, show, eq]

(** fusion 발동 사유 — 게이트 입력. catch-all 없음.
    결정론적 게이트가 각 변형을 config 상한과 대조한다 (RFC-0252 §6). *)
type fusion_trigger =
  | Explicit_tool_call  (** 키퍼가 masc_fusion을 직접 호출 *)
  | Low_confidence of low_confidence  (** 단일 모델 확신도가 임계 미만 *)
  | High_stakes of string  (** task_kind이 config 목록에 있음 *)
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
  | Over_hourly_budget  (** per_hour_budget 초과 *)
  | Not_warranted  (** 트리거가 게이트 조건 미충족 (예: low_confidence인데 score≥threshold) *)
[@@deriving yojson, show, eq]

(** 안정적 짧은 라벨 (로깅·메트릭용). *)
val deny_reason_label : deny_reason -> string

(** 게이트 출력 — 통과(요청 반환) 또는 거부(사유). *)
type gate_decision =
  | Allow of fusion_request
  | Deny of deny_reason
[@@deriving yojson, show, eq]
