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
    passing a [Computed] value to {!project}. [on_progress], when supplied,
    receives process-local panel, judge, and computed stage transitions; it is
    observation only and is not resumable after restart. *)
val compute
  :  base_dir:string
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> policy:Fusion_policy.t
  -> topology:Fusion_types.fusion_topology
  -> request:Fusion_types.fusion_request
  -> ?on_progress:(Fusion_run_registry.progress -> unit)
  -> unit
  -> compute_outcome

(** Project one already-computed deliberation to the existing sink. *)
val project
  :  ?source_context:Fusion_request_context.t
  -> registry:Fusion_run_registry.t
  -> base_dir:string
  -> topology:Fusion_types.fusion_topology
  -> channel:Keeper_continuation_channel.t
  -> request:Fusion_types.fusion_request
  -> Fusion_types.deliberation_evidence
  -> (unit, string) result

(** Substitute the direct panel and judge I/O while exercising the same
    policy, topology, accounting and evidence assembly as production. *)
module type Panel_effect = sig
  val run
    :  base_dir:string
    -> sw:Eio.Switch.t
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> groups:Fusion_policy.panel_group list
    -> prompt:string
    -> ?on_tool_trace:(Fusion_types.tool_trace -> unit)
    -> ?on_seat_routes:(Fusion_types.seat_route list -> unit)
    -> unit
    -> Fusion_types.panel_outcome list
end

module type Judge_effect = sig
  val run
    :  base_dir:string
    -> sw:Eio.Switch.t
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?max_tokens:int
    -> ?timeout_s:float
    -> judge_system_prompt:string
    -> judge_model:string
    -> question:string
    -> panel:Fusion_types.panel_outcome list
    -> web_tools:bool
    -> ?tool_trace:
         (Fusion_types.tool_trace_actor * (Fusion_types.tool_trace -> unit))
    -> ?seat_route:(Fusion_types.judge_role * (Fusion_types.seat_route -> unit))
    -> unit
    -> ( Fusion_types.judge_synthesis * Fusion_types.usage
       , Fusion_types.judge_failure * Fusion_types.usage )
       result

  val run_refine
    :  base_dir:string
    -> sw:Eio.Switch.t
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?max_tokens:int
    -> ?timeout_s:float
    -> judge_system_prompt:string
    -> judge_model:string
    -> question:string
    -> panel:Fusion_types.panel_outcome list
    -> prior:Fusion_types.judge_synthesis
    -> web_tools:bool
    -> ?tool_trace:
         (Fusion_types.tool_trace_actor * (Fusion_types.tool_trace -> unit))
    -> ?seat_route:(Fusion_types.judge_role * (Fusion_types.seat_route -> unit))
    -> unit
    -> ( Fusion_types.judge_synthesis * Fusion_types.usage
       , Fusion_types.judge_failure * Fusion_types.usage )
       result

  val run_meta
    :  base_dir:string
    -> sw:Eio.Switch.t
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?max_tokens:int
    -> ?timeout_s:float
    -> judge_system_prompt:string
    -> judge_model:string
    -> question:string
    -> panel:Fusion_types.panel_outcome list
    -> priors:(string * Fusion_types.judge_synthesis) list
    -> web_tools:bool
    -> ?tool_trace:
         (Fusion_types.tool_trace_actor * (Fusion_types.tool_trace -> unit))
    -> ?seat_route:(Fusion_types.judge_role * (Fusion_types.seat_route -> unit))
    -> unit
    -> ( Fusion_types.judge_synthesis * Fusion_types.usage
       , Fusion_types.judge_failure * Fusion_types.usage )
       result
end

module For_testing : sig
  module Make (Panel : Panel_effect) (Judge : Judge_effect) : sig
    val compute
      :  base_dir:string
      -> sw:Eio.Switch.t
      -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
      -> policy:Fusion_policy.t
      -> topology:Fusion_types.fusion_topology
      -> request:Fusion_types.fusion_request
      -> ?on_progress:(Fusion_run_registry.progress -> unit)
      -> unit
      -> compute_outcome
  end
end
