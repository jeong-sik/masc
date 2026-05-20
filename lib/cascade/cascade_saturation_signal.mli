(** Cascade_saturation_signal — Typed signal for tier saturation events.

    Phase A.1 of RFC-0153 (Cascade Backpressure & Tier Admission).

    이 모듈은 cascade tier 가 "saturated" 상태일 때 caller 에게 전달되는
    typed signal 을 정의한다. 종전의 hard timer kill / "cascade exhausted"
    string 경로를 대체하는 *추가-only* 신호 채널.

    핵심 의도:
    - `max_execution_time_s` hard cap 이 fire 됐다는 것을 *kill switch*
      대신 *signal emit* 로 변환.
    - caller (예: keeper_turn_driver) 가 남은 turn deadline + signal 종류
      를 보고 retry / wait / fail 을 결정.
    - Phase A.1 단독으로는 *동작 변경 없음*. Phase A.2 (caller dispatch),
      Phase B (tier admission), Phase C (adaptive throttle) 가 본 signal
      을 입력으로 받음.

    외부 검증:
    - OpenClaw [docs/concepts/retry.md] : SDK wait > 60s 시
      [x-should-retry: false] inject → failover escalate. 동일 원칙.
    - Hermes Agent [agent/nous_rate_guard.py] :
      [is_genuine_nous_rate_limit] 가 quota 와 upstream transient 분리.

    @since RFC-0153 Phase A.1 *)

(** {1 Typed signal variants} *)

type t =
  | Provider_rate_limited of {
      provider_id : string;
      retry_after_ms : int option;
    }
      (** 호출한 provider 가 명시적 rate limit 응답 (HTTP 429 +
          Retry-After header). [retry_after_ms] 가 있으면 그 시간만큼
          기다린 후 동일 provider 재시도가 합리적. *)
  | Time_cap_fired of {
      observed_latency_ms : int;
      cap_ms : int;
      provider_id : string option;
    }
      (** Wall-clock cap (예: [max_execution_time_s]) 가 fire 됐다.
          종전에는 즉시 cascade attempt cancel + "cascade exhausted"
          로 propagate 됐으나, RFC-0153 후 caller 가 *남은 turn
          deadline* 과 이 signal 을 보고 retry 여부 결정.

          [provider_id = None] 인 경우는 cascade 단에서 어떤 provider
          도 응답을 시작하지 않은 상태에서 cap fire. *)
  | All_tiers_filtered_after_cycles of {
      cascade_name : string;
      cycle_count : int;
    }
      (** Cycle 반복 후 모든 후보가 cooldown / health filter 로 제거.
          종전의 [candidates_filtered_after_cycles] 의 typed 등가물.
          *Time_cap_fired 의 downstream symptom 이 아니라 독립
          신호인지* 는 caller 가 [observed_latency_ms] 와 함께 판단. *)
  | Inflight_capacity_full of {
      tier_id : string;
      max_inflight : int;
    }
      (** Phase B (tier admission semaphore) 가 도입된 후 사용.
          현재 tier 의 동시 inflight 가 [max_inflight] 에 도달하여
          새 요청을 받지 못하는 상태. Phase A.1 시점에는 이 variant
          가 emit 되지 않으나, type-level 에서 미리 자리를 잡아
          Phase B 추가 시 caller 의 match 가 자동으로 깨지도록 함. *)

(** {1 Serialization} *)

val to_log_string : t -> string
(** Human-readable log line. 형식 예:
    - ["provider_rate_limited provider=runpod_mtp retry_after_ms=1200"]
    - ["time_cap_fired observed_latency_ms=300100 cap_ms=300000 provider=glm-coding"]
    - ["all_tiers_filtered_after_cycles cascade=strict_tool_candidates cycles=3"]
    - ["inflight_capacity_full tier=strict_tool_candidates max_inflight=8"]

    동일 형식이 Prometheus metric label 과 audit log 에 사용된다. *)

val to_metric_label : t -> string
(** Prometheus metric label 용 짧은 형태. variant kind 만 포함하고
    payload 는 다른 label 로 분리된다. 예: ["time_cap_fired"]. *)

val to_yojson : t -> Yojson.Safe.t
(** Audit log (`.masc/cascade_audit/*.jsonl`) 직렬화. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Round-trip 용. Phase A.1 test 에서 사용. *)

(** {1 Pretty} *)

val pp : Format.formatter -> t -> unit
(** Format printer. [%a] 와 함께 사용. *)

val equal : t -> t -> bool
(** 같은 variant + 같은 payload 일 때 true. test 용. *)

(** {1 Variant kind (closed sum tag)} *)

type kind =
  | K_provider_rate_limited
  | K_time_cap_fired
  | K_all_tiers_filtered_after_cycles
  | K_inflight_capacity_full

val kind : t -> kind
(** Payload 와 분리된 variant tag. metric label / dashboard
    aggregation 에 사용. exhaustive match 강제. *)

val kind_to_string : kind -> string
(** [K_time_cap_fired] -> ["time_cap_fired"] 등. *)
