(** Fusion — [masc_fusion] 키퍼 도구의 핸들러 로직.

    키퍼 dispatch arm(lib/keeper)이 이 [handle]을 호출한다. 배선(descriptor/schema/
    typed match arm)은 키퍼 쪽에 얇게 두고, 게이트·예산·fiber fork 로직은 여기 둔다.

    동작(RFC-0252 §4): args에서 prompt/preset/web_tools를 typed 파싱 → 게이트 판정
    → [Allow]면 [Eio.Fiber.fork ~sw]로 out-of-band 심의를 띄우고 즉시 status JSON
    반환(키퍼는 막히지 않음). [Deny]면 fiber 없이 사유를 즉시 반환(예산 미소모).

    설계 SSOT: docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md §4/§6 *)

(** 서버 단일 시간당 예산 카운터. 키퍼 dispatch가 프로세스당 하나를 공유한다. *)
val budget : Fusion_budget.t

(** 유닉스초 → UTC hour bucket ["YYYY-MM-DDTHH"] (예산 윈도우 키). 시각은 주입. *)
val hour_bucket_of_unix : float -> string

(** [masc_fusion] 호출 처리. status JSON 문자열을 반환한다.

    @param now_unix 현재 유닉스초 (키퍼 clock에서; hour_bucket 산출).
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
