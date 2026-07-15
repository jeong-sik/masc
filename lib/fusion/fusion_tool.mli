(** Fusion — [masc_fusion] 키퍼 도구의 핸들러 로직.

    키퍼 dispatch arm(lib/keeper)이 이 [handle]을 호출한다. 배선(descriptor/schema/
    typed match arm)은 키퍼 쪽에 얇게 두고, 게이트·fiber fork 로직은 여기 둔다.

    동작(RFC-0252 §4): args에서 prompt/preset/web_tools를 typed 파싱 → 정책 게이트 판정
    → [Allow]면 [Eio.Fiber.fork ~sw]로 out-of-band 심의를 띄우고 즉시 status JSON
    반환(키퍼는 막히지 않음). [Deny]면 fiber 없이 사유를 즉시 반환.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §4/§6 *)

type recovery_failure =
  | Completion_address_unavailable of Fusion_wake_route.error
  | Recovery_claim_failed of Fusion_run_registry.claim_error
  | Recovery_start_failed of Fusion_run_registry.start_error

type recovery_report =
  { started : int
  ; failures : (string * recovery_failure) list
  }

val recovery_failure_to_string : recovery_failure -> string
val recover_required :
  sw:Eio.Switch.t -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  base_dir:string -> policy:Fusion_policy.t -> recovery_report

(** [masc_fusion] 호출 처리. status JSON 문자열을 반환한다.

    @param now_unix 현재 유닉스초 (키퍼 clock에서; run 시작 시각 기록).
    @param run_id correlation id (호출자가 생성 — fusion_tool은 무작위성 비포함).
    @param policy runtime.toml [fusion]에서 로드한 정책.
    @param continuation_channel 호출 턴이 시작된 connector 대화(RFC-0320).
           [Allow] 시 {!Fusion_wake_route}에 등록되어 [Fusion_completed] wake가
           원 채널로 회신을 라우팅할 수 있게 한다. 생략/Unrouted면 미등록.
    @param args 도구 입력 JSON (prompt 필수; preset/web_tools 선택). *)
val handle
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> base_dir:string
  -> keeper:string
  -> now_unix:float
  -> run_id:string
  -> policy:Fusion_policy.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> args:Yojson.Safe.t
  -> unit
  -> string

val handle_result
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> base_dir:string
  -> keeper:string
  -> now_unix:float
  -> run_id:string
  -> policy:Fusion_policy.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> args:Yojson.Safe.t
  -> unit
  -> Tool_result.result

module For_test : sig
  (** [handle]이 background fiber에서 실행하는 orchestrator contract.

      기본값은 {!Fusion_orchestrator.run}이다. 테스트는 이 contract를 주입해 handler의
      async delivery wiring(Running 등록, background 완료 후 sink/registry projection)을
      실제 provider 호출 없이 결정적으로 검증한다. *)
  type orchestrator_runner =
    sw:Eio.Switch.t
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> base_dir:string
    -> policy:Fusion_policy.t
    -> topology:Fusion_types.fusion_topology
    -> request:Fusion_types.fusion_request
    -> unit
    -> Fusion_orchestrator.outcome

  val recover_required_with_runner :
    run_orchestrator:orchestrator_runner -> sw:Eio.Switch.t ->
    net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t -> base_dir:string ->
    policy:Fusion_policy.t -> recovery_report

  (** [handle]과 같은 계약이되 background runner를 명시적으로 받는다.

      Production dispatch는 {!handle}만 호출한다. 이 함수는 provider/network 시간을
      끌어들이지 않고 handler의 async state transition을 테스트하기 위한 동일-contract
      entrypoint다. *)
  val handle_with_runner
    :  run_orchestrator:orchestrator_runner
    -> sw:Eio.Switch.t
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> base_dir:string
    -> keeper:string
    -> now_unix:float
    -> run_id:string
    -> policy:Fusion_policy.t
    -> ?continuation_channel:Keeper_continuation_channel.t
    -> args:Yojson.Safe.t
    -> unit
    -> string
end
