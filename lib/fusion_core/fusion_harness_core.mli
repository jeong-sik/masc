(** Fusion 하네스 — self-consistency 다수결 집계 (결정론).

    fusion 평가에서 "이 답이 정답인가 / 어느 전략이 나은가"는 judge(LLM 판단)가
    한다. 결정론 string 매칭으로 정답을 채점하는 것은 두지 않는다 — 표현 변이
    ("42" vs "The answer is 42")를 못 잡고, 심의 가치를 단답 정답률로 환원하는
    어거지다. 이 모듈은 판단이 불필요한 한 가지, self-consistency의 다수결 집계만
    결정론으로 제공한다(같은 답이 몇 번 나왔나를 세는 것 = 판단이 아니라 집계).
    토큰 비용 실측은 {!Fusion_types.add_usage}로, 채점·전략 우열은 judge가 담당한다.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §11 *)

(** 다수결 집계 (self-consistency) — 결정론. 정규화(trim + lowercase + 내부 공백
    1칸 축약) 키로 최빈 답을 고르고, 동률이면 입력에서 먼저 등장한 답의 원문을
    반환한다. 빈 리스트는 [Invalid_argument] (호출자가 non-empty 보장; N≥1). *)
val majority_vote : string list -> string
