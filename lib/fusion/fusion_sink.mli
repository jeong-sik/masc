(** Fusion — 심의 결과 가시화. 패널 답 N개 + 심판 종합을 요청 키퍼의 chat lane에
    authored 메시지로 append하고 SSE 브로드캐스트한다 → 대시보드가 자동 반영
    (keeper chat lane이 곧 대시보드에 렌더되므로 "키퍼 개별 채팅"+"대시보드" 동시 충족).

    [run_id]를 [conversation_id]([fusion/<run_id>])로 써서 한 심의의 모든 voice를
    하나의 서브스레드로 묶어 증명한다. 패널 참가자는 모델이므로 [model]: 접두로 귀속한다.

    두 surface(사용자 가시성 요구, RFC-0255 §3): (1) keeper chat lane = 사람이 읽는
    *서사*, (2) board post([Board.System_post] + [meta_json] 구조화 증거) = run_id로
    묶인 쿼리 가능한 *증거*. 둘 다 대시보드에 도달한다.

    설계 SSOT: docs/rfc/RFC-0255-fusion-panel-judge-deliberation.md §8 *)

(** 심의 트랜스크립트를 키퍼 chat lane에 기록하고 board에 구조화 증거를 post한다.

    순서: 헤더(질문) → 패널 답/실패(모델 순) → usage 관측 → 심판 종합. 모두 [base_dir]의
    keeper_chat에 append되고, [chat_appended]로 대시보드에 알린 뒤 [Board_dispatch.create_post]로
    meta_json([fusion_deliberation] 래퍼, RFC-0255 §8.2) 증거를 남긴다. [base_dir]는
    호출자(orchestrator)가 주입한다.

    chat store append, broadcast, board post 중 예외가 발생하면 [Error msg]를 반환한다.
    [Eio.Cancel.Cancelled]는 재전파한다. *)
val emit
  :  base_dir:string
  -> keeper:string
  -> run_id:string
  -> preset:string
  -> trigger:Fusion_types.fusion_trigger
  -> question:string
  -> panel:Fusion_types.panel_outcome list
  -> judge:(Fusion_types.judge_synthesis, string) result
  -> judge_model:string
  -> start_time_unix:float
  -> (unit, string) result
