(** Fusion — 심의 결과 가시화. 패널 답 N개 + 심판 종합을 요청 키퍼의 chat lane에
    authored 메시지로 append하고 SSE 브로드캐스트한다 → 대시보드가 자동 반영
    (keeper chat lane이 곧 대시보드에 렌더되므로 "키퍼 개별 채팅"+"대시보드" 동시 충족).

    [run_id]를 [conversation_id]([fusion/<run_id>])로 써서 한 심의의 모든 voice를
    하나의 서브스레드로 묶어 증명한다. 패널 참가자는 모델이므로 [model]: 접두로 귀속한다.

    v1: keeper chat lane만. board post(meta_json 전역 증거)는 Phase 3b.

    설계 SSOT: docs/rfc/RFC-0249-fusion-panel-judge-deliberation.md §8 *)

(** 심의 트랜스크립트를 키퍼 chat lane에 기록한다.

    순서: 헤더(질문) → 패널 답/실패(모델 순) → 심판 종합. 모두 [base_dir]의
    keeper_chat에 append되고, 끝에 한 번 [chat_appended]로 대시보드에 알린다.
    [base_dir]는 호출자(orchestrator)가 키퍼 턴 컨텍스트에서 주입한다. *)
val emit
  :  base_dir:string
  -> keeper:string
  -> run_id:string
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> judge:(Fusion_types.judge_synthesis, string) result
  -> unit
