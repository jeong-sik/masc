(** Fusion — [masc_fusion] 키퍼 도구의 핸들러 로직.

    키퍼 dispatch arm(lib/keeper)이 이 [handle]을 호출한다. 배선(descriptor/schema/
    typed match arm)은 키퍼 쪽에 얇게 두고, 게이트·fiber fork 로직은 여기 둔다.

    동작(RFC-0252 §4): args에서 prompt/preset/web_tools를 typed 파싱 → 정책 게이트 판정
    → [Allow]면 [Eio.Fiber.fork ~sw]로 out-of-band 심의를 띄우고 즉시 status JSON
    반환(키퍼는 막히지 않음). [Deny]면 fiber 없이 사유를 즉시 반환.

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §4/§6 *)

(** Stable [failure_code] for a run that is stopped by structural Eio
    cancellation. This is a producer-owned status value, not a parser
    derived from free text. *)
val structural_cancel_failure_code : string

(** Human-readable failure payload paired with
    {!structural_cancel_failure_code}. It is used consistently for the
    registry failure reason and the typed [Fusion_completed] wake payload. *)
val structural_cancel_failure : string

(** Complete a structurally-cancelled fusion run and deliver the same typed
    wake contract as other failure paths.

    The registry transition is performed before any suspending operation. The
    broadcast and [Fusion_completed] wake run under [Eio.Cancel.protect] so the
    cancellation handler can do explicit cleanup before its caller re-raises the
    original [Eio.Cancel.Cancelled]. *)
val finalize_cancelled_run
  :  base_dir:string
  -> keeper:string
  -> run_id:string
  -> unit

(** [masc_fusion] 호출 처리. status JSON 문자열을 반환한다.

    @param now_unix 현재 유닉스초 (키퍼 clock에서; run 시작 시각 기록).
    @param run_id correlation id (호출자가 생성 — fusion_tool은 무작위성 비포함).
    @param policy runtime.toml [fusion]에서 로드한 정책.
    @param args 도구 입력 JSON (prompt 필수; preset/web_tools 선택). *)
val handle
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> base_dir:string
  -> keeper:string
  -> now_unix:float
  -> run_id:string
  -> policy:Fusion_policy.t
  -> args:Yojson.Safe.t
  -> string
