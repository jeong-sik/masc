(** Fusion — out-of-band 심의 오케스트레이터. 한 요청에 대해
    gate → panel → judge → sink 를 순서대로 실행한다.

    {b 비차단은 호출자 책임}: 본 함수는 동기적이다(패널 N + 심판 1 완성을 기다림,
    ~7× 지연). 키퍼 턴을 막지 않으려면 호출자(예: masc_fusion 도구)가 별도
    Eio fiber로 fork해서 호출하고, 키퍼는 즉시 진행한다(RFC-0255 §4).

    설계 SSOT: docs/rfc/RFC-0255-fusion-panel-judge-deliberation.md §4 *)

(** 오케스트레이션 결과 (닫힌 합). *)
type outcome =
  | Denied of Fusion_types.deny_reason  (** 게이트가 거부 *)
  | Sink_failed of string  (** chat lane 기록 실패 *)
  | Completed of
      { panel : Fusion_types.panel_outcome list
      ; judge : (Fusion_types.judge_synthesis, string) result
      }

(** 요청을 심의한다.

    + [Fusion_policy.decide]로 정책 판정 → [Deny]면 [Denied] 반환(부작용 없음).
    + [Allow]면 [Fusion_budget.try_incr_if_under]로 시간당 예산을 원자적으로 소비.
      예산 초과면 [Denied Over_hourly_budget]을 반환한다.
    + 예산 소비 후 preset의 패널 모델로 [Fusion_panel.run], judge 모델로 [Fusion_judge.run].
      패널/심판 system prompt와 타임아웃은 preset(=config)에서 온다 — 코드 default 없음.
    + [Fusion_sink.emit]으로 트랜스크립트를 키퍼 chat lane에 기록. 실패면 [Sink_failed].
    + [Completed]로 패널/심판 결과 반환.

    @param budget 서버 단일 시간당 예산 카운터.
    @param hour_bucket 현재 UTC 시간 윈도우 키. *)
val run
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> base_dir:string
  -> budget:Fusion_budget.t
  -> hour_bucket:string
  -> policy:Fusion_policy.t
  -> request:Fusion_types.fusion_request
  -> unit
  -> outcome
