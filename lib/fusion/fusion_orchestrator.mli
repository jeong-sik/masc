(** Fusion — out-of-band 심의 오케스트레이터. 한 요청에 대해
    gate → panel → judge → sink 를 순서대로 실행한다.

    {b 비차단은 호출자 책임}: 본 함수는 동기적이다(패널 N + 심판 1 완성을 기다림,
    ~7× 지연). 키퍼 턴을 막지 않으려면 호출자(예: masc_fusion 도구)가 별도
    Eio fiber로 fork해서 호출하고, 키퍼는 즉시 진행한다(RFC-0252 §4).

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §4 *)

(** 오케스트레이션 결과 (닫힌 합). *)
type outcome =
  | Denied of Fusion_types.deny_reason  (** 게이트가 거부 *)
  | Sink_failed of string  (** chat lane 기록 실패 *)
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, Fusion_types.judge_failure) result
      }

(** 요청을 심의한다.

    + [Fusion_policy.decide]로 정책 판정 → [Deny]면 [Denied] 반환(부작용 없음).
    + [Allow]면 preset의 패널 모델로 [Fusion_panel.run], judge 모델로 [Fusion_judge.run].
      패널/심판 system prompt와 타임아웃은 preset(=config)에서 온다 — 코드 default 없음.
    + [topology]에 따라 reduce 위상을 고른다: [Simple]은 panel→judge→sink(현행),
      [Refine]은 panel→judge→judge'(1차 종합 재검토)→sink, [Conditional]은 1차 판정이
      [Insufficient]일 때만 refine하고 그 외엔 [Simple]처럼 1차 종합 그대로
      ([Fusion_types.decision_warrants_escalation]), [Judge_of_judges]는 preset.judges의
      N개(>=2) 1차 심판이 같은 패널을 병렬 독립 종합하고 preset.judge(meta)가 reconcile한다
      (RFC-0283; judges<2면 에러, 1차 전원 실패면 첫 에러, meta 실패면 1차 첫 성공으로 degrade).
      [Staged_judge_of_judges]는 같은 1차 심판 목록을
      [policy.staged_judge_group_size]의 정확한 그룹들로 줄이고, 각 stage meta 결과를
      final meta가 다시 reconcile한다. ragged/too-small judge 목록은 실행 전 에러로
      fail-closed하며, nested [masc_fusion] 호출은 하지 않는다.
      단일-심판 위상에서 1차 심판이 실패하면 [Simple]과 동일하게 에러를 전파하고,
      refine(2차)/meta 심판이 실패하면 1차 종합으로 graceful degrade한다(warn 로깅).
      refine/JOJ는 관여한 심판 usage를 모두 합산해 sink로 보낸다.
    + [Fusion_sink.emit]으로 트랜스크립트를 키퍼 chat lane에 기록. 실패면 [Sink_failed].
    + [Completed]로 패널/심판 결과 반환. *)
val run
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> config:Workspace.config
  -> base_dir:string
  -> policy:Fusion_policy.t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> unit
  -> outcome
