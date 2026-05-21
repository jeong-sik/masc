(** Telemetry protocol for capacity_backpressure events.
    
    막장 트위스트: 30 회 연속 실패는 '기다리면 풀린다'는 가정이 틀렸다는 증거.
    cascade tier 가 3 개지만 모두 동일한 capacity key 를 공유하므로 fallback 은 환상.
    retry_after_sec=null 은 "기다려도 소용없다"는 시그널.
    
    이 프로토콜은 capacity_backpressure 발생 시 다음을 기록한다:
    - 어떤 cascade tier 를 거쳤는지
    - 실제 막힌 capacity key 는 무엇인지
    - retry_after 가 null 인 이유 (API 미지원 vs 의도적 생략)
    - 대안 경로가 있었는지
    - 이 capacity 요청에 이르기 위한 결정 체인
*)

type cascade_tier = 
  | Primary
  | Strict_tool_candidates
  | Tier_group_strict_tool_candidates
  | Other of string

type capacity_source =
  | Client_capacity
  | Server_capacity
  | Rate_limit
  | Unknown

type retry_after_status =
  | Provided of int (* seconds *)
  | Null_api_not_supported
  | Null_intentional_no_wait
  | Missing

type alternative_path = {
  path_name : string;
  was_tried : bool;
  failure_reason : string option;
}

type decision_chain_step = {
  step_name : string;
  decision : string;
  alternatives_considered : string list;
  timestamp : float;
}

type capacity_backpressure_event = {
  event_id : string;
  timestamp : float;
  cascade_name : cascade_tier;
  source : capacity_source;
  capacity_key : string; (* 예: "https://api.z.ai/api/coding/paas/v4" *)
  detail : string;
  retry_after : retry_after_status;
  alternative_paths : alternative_path list;
  decision_chain : decision_chain_step list;
  consecutive_failures : int; (* 연속 실패 횟수 — 30 회 이상이면 root cause 탐색 트리거 *)
  recovery_action_taken : string option; (* 취해진 회복 조치 *)
}

(** 30 회 연속 실패 패턴 감지 시 트리거할 액션 *)
type recovery_action =
  | Switch_to_alternative_provider
  | Enable_local_only_mode
  | Circuit_breaker_open
  | Escalate_to_operator
  | No_action_retry_later

let should_trigger_root_cause_analysis (event : capacity_backpressure_event) : bool =
  event.consecutive_failures >= 30

let should_open_circuit_breaker (event : capacity_backpressure_event) : bool =
  event.consecutive_failures >= 5 && 
  event.retry_after = Null_api_not_supported

let get_recovery_action (event : capacity_backpressure_event) : recovery_action =
  if event.consecutive_failures >= 30 then Escalate_to_operator
  else if event.consecutive_failures >= 5 && event.retry_after = Null_api_not_supported then Circuit_breaker_open
  else if event.consecutive_failures >= 3 then Switch_to_alternative_provider
  else No_action_retry_later

(* 텔레메트리 수집 인터페이스 *)
module type TelemetryCollector = sig
  val record_capacity_backpressure : capacity_backpressure_event -> unit
  val get_consecutive_failures : capacity_key:string -> int
  val reset_failure_count : capacity_key:string -> unit
end