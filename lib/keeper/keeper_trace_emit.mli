(** Keeper_trace_emit — TLA+ trace validation용 상태 전이 기록.

    MASC_TLA_TRACE=1 환경변수가 설정된 경우에만 활성화.
    비활성 시 모든 함수는 no-op. *)

(** MASC_TLA_TRACE 환경변수 확인. 결과는 프로세스 수명 동안 캐시. *)
val enabled : unit -> bool

(** [base_path]/keepers/[keeper_name].tla-trace.jsonl 에 JSONL 한 줄 append.
    비활성 시 no-op. *)
val emit_transition
  :  keeper_name:string
  -> base_path:string
  -> seq:int
  -> event:Keeper_state_machine.event
  -> prev_phase:Keeper_state_machine.phase
  -> new_phase:Keeper_state_machine.phase
  -> conditions_after:Keeper_state_machine.conditions
  -> restart_count:int
  -> unit

(** Trace 파일 경로 반환. *)
val trace_path : base_path:string -> keeper_name:string -> string
