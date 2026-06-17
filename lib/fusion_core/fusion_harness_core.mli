(** Fusion 하네스 코어 — 4 비교 전략의 결정론 집계·채점·delta (RFC-0252 §11).

    single / self-consistency / Self-MoA / fusion은 "panel 구성 × 집계 방식"의 4조합이며
    fusion 인프라(panel+judge)를 재사용한다. 실모델 샘플 생성과 judge 종합(비결정론)은 이
    모듈 밖(수동 실행 bin)에서 수행하고, 그 결과([run_result] 리스트)를 여기 순수 함수에
    먹여 비교한다. 다수결 집계·정답 매칭·4-way delta는 전부 결정론이라 mock [run_result]로
    로컬 테스트된다(test/fusion_core/test_fusion_harness.ml). 이 경계 분리가 "Harness First"
    의 측정 가능성·재현성을 OAS 없이 확보하는 방법이다. 설계 SSOT: RFC-0252 §11. *)

(** 4 비교 전략. 모두 "N 샘플 → 집계"의 변형이며 fusion 인프라를 재사용한다:
    - [Single]: panel 1개, 집계 없음 (1× 비용 baseline)
    - [Self_consistency]: panel N개(동일 모델 N회), 다수결 집계 (결정론, judge 불필요)
    - [Self_moa]: panel N개(최강 모델 N회), judge 종합 집계
    - [Fusion]: panel N개(이종 모델), judge 종합 집계 *)
type strategy =
  | Single
  | Self_consistency
  | Self_moa
  | Fusion

val strategy_label : strategy -> string

(** 고정 eval 케이스. [reference]는 정답(정답 매칭 채점용). *)
type eval_case =
  { question : string
  ; reference : string
  }
[@@deriving yojson]

(** 한 전략이 한 케이스에서 낸 결과. [answer]는 집계된 최종 답, [correct]는 [reference]
    매칭 여부, [usage]는 그 전략 1회가 쓴 총 토큰(panel + judge 합산). *)
type run_result =
  { strategy : strategy
  ; answer : string
  ; correct : bool
  ; usage : Fusion_types.usage
  }

(** 4-way 비교 산출. *)
type comparison =
  { score : (strategy * float) list
      (** 전략별 정답률 (correct 수 / 케이스 수), 0.0..1.0. 전략의 run이 0개면 0.0. *)
  ; cost_ratio : (strategy * float) list
      (** single 대비 토큰 비용 배수 (single=1.0). single 토큰이 0이면 0.0. *)
  ; cost_matched_delta : float
      (** 핵심 게이트: [Fusion] 정답률 − max([Self_consistency], [Self_moa]) 정답률.
          single 대비가 아니라 *같은 비용을 다르게 쓴 대안* 대비다 — 이게 양수여야
          fusion이 "모델 다양성 + judge 종합"으로 4× 비용을 정당화한다. 음수/0이면
          fusion의 우위는 "컴퓨트 더 씀"일 뿐 (RFC §11, MAD/Self-MoA). *)
  ; single_delta : float
      (** 참고용: [Fusion] − [Single] 정답률. 양수는 컴퓨트 증가로 자명, 정당화 근거 못 됨. *)
  }

(** 다수결 집계 (self-consistency) — 결정론. 정규화([normalize]) 키로 최빈 답을 고르고,
    동률이면 입력에서 먼저 등장한 답의 원문을 반환한다. 빈 리스트는 [Invalid_argument]
    (호출자가 non-empty 보장; self-consistency는 N≥1). *)
val majority_vote : string list -> string

(** 정답 매칭 채점 — 결정론. [reference]와 [answer]를 정규화(trim + lowercase + 내부
    공백 1칸 축약) 후 동등 비교. 의미적 동등(다른 표현·같은 뜻)은 못 잡으므로 eval 셋은
    정답이 단답/명확한 케이스로 구성한다. *)
val score_answer : reference:string -> answer:string -> bool

(** [run_result] 리스트(전략 × 케이스)를 4-way [comparison]으로 집계 — 결정론. 각 전략이
    각 케이스를 0..N회 돈 결과를 받아 전략별 정답률·비용비·delta를 계산한다. *)
val compare : run_result list -> comparison
