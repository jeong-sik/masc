(** Fusion — 심의 계산과 durable terminal 투영을 분리한 오케스트레이터.

    {b 비차단은 호출자 책임}: 본 함수는 동기적이다(패널 N + 심판 1 완성을 기다림,
    ~7× 지연). [Fusion_tool]은 이를 [Keeper_msg_async] worker에서 실행하고 키퍼
    턴에는 canonical request id만 즉시 반환한다(RFC-0252 §4).

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §4 *)

(** 오케스트레이션 결과 (닫힌 합). *)
type compute_outcome =
  | Compute_denied of Fusion_types.deny_reason
  | Computed of Fusion_types.deliberation_evidence

(** Run panel and judge computation without Board, chat, wake, or run-registry
    projection. The caller can durably claim the semantic terminal before
    passing a [Computed] value to {!project}. *)
val compute
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> policy:Fusion_policy.t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> unit
  -> compute_outcome

(** Project one already-computed deliberation to the existing sink. *)
val project
  :  base_dir:string
  -> topology:Fusion_types.fusion_topology
  -> channel:Keeper_continuation_channel.t
  -> request:Fusion_types.fusion_request
  -> Fusion_types.deliberation_evidence
  -> (unit, string) result
