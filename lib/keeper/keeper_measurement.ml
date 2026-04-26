(** Keeper Measurement — Det/NonDet Boundary Types (RFC-0002).
    Phase 1: types and serialization.
    Phase 4: pure [capture] function. *)

type threshold_params =
  { compaction_ratio_gate : float
  ; compaction_message_gate : int
  ; compaction_token_gate : int
  ; compaction_cooldown_sec : int
  ; handoff_threshold : float
  ; handoff_cooldown_sec : int
  ; auto_handoff_enabled : bool
  ; reflect_repetition_threshold : float
  ; plan_goal_alignment_threshold : float
  ; plan_response_alignment_threshold : float
  ; guardrail_repetition_threshold : float
  ; guardrail_goal_alignment_threshold : float
  ; guardrail_response_alignment_threshold : float
  ; guardrail_context_threshold : float
  ; max_consecutive_hb_failures : int
  ; max_consecutive_turn_failures : int
  ; model_ratio_multiplier : float
  ; model_handoff_multiplier : float
  }

type context_measurement =
  { context_ratio : float
  ; message_count : int
  ; token_count : int
  ; max_tokens : int
  }

type similarity_measurement =
  { repetition_risk : float
  ; goal_alignment : float
  ; response_alignment : float
  ; similarity_measurable : bool
  }

type timing_measurement =
  { now_ts : float
  ; idle_seconds : int
  ; since_last_compaction_sec : float
  ; since_last_handoff_sec : float
  ; proactive_warmup_elapsed : bool
  }

type failure_measurement =
  { consecutive_hb_failures : int
  ; consecutive_turn_failures : int
  }

type measurement_snapshot =
  { snapshot_id : string
  ; keeper_name : string
  ; generation : int
  ; timestamp : float
  ; thresholds : threshold_params
  ; context : context_measurement
  ; similarity : similarity_measurement
  ; timing : timing_measurement
  ; failures : failure_measurement
  }

let threshold_params_to_json (t : threshold_params) : Yojson.Safe.t =
  `Assoc
    [ "compaction_ratio_gate", `Float t.compaction_ratio_gate
    ; "compaction_message_gate", `Int t.compaction_message_gate
    ; "compaction_token_gate", `Int t.compaction_token_gate
    ; "compaction_cooldown_sec", `Int t.compaction_cooldown_sec
    ; "handoff_threshold", `Float t.handoff_threshold
    ; "handoff_cooldown_sec", `Int t.handoff_cooldown_sec
    ; "auto_handoff_enabled", `Bool t.auto_handoff_enabled
    ; "reflect_repetition_threshold", `Float t.reflect_repetition_threshold
    ; "plan_goal_alignment_threshold", `Float t.plan_goal_alignment_threshold
    ; "plan_response_alignment_threshold", `Float t.plan_response_alignment_threshold
    ; "guardrail_repetition_threshold", `Float t.guardrail_repetition_threshold
    ; "guardrail_goal_alignment_threshold", `Float t.guardrail_goal_alignment_threshold
    ; ( "guardrail_response_alignment_threshold"
      , `Float t.guardrail_response_alignment_threshold )
    ; "guardrail_context_threshold", `Float t.guardrail_context_threshold
    ; "max_consecutive_hb_failures", `Int t.max_consecutive_hb_failures
    ; "max_consecutive_turn_failures", `Int t.max_consecutive_turn_failures
    ; "model_ratio_multiplier", `Float t.model_ratio_multiplier
    ; "model_handoff_multiplier", `Float t.model_handoff_multiplier
    ]
;;

let capture
      ~snapshot_id
      ~keeper_name
      ~generation
      ~timestamp
      ~thresholds
      ~context_ratio
      ~message_count
      ~token_count
      ~max_tokens
      ~repetition_risk
      ~goal_alignment
      ~response_alignment
      ?(similarity_measurable = true)
      ~now_ts
      ~idle_seconds
      ~since_last_compaction_sec
      ~since_last_handoff_sec
      ~proactive_warmup_elapsed
      ~consecutive_hb_failures
      ~consecutive_turn_failures
      ()
  : measurement_snapshot
  =
  { snapshot_id
  ; keeper_name
  ; generation
  ; timestamp
  ; thresholds
  ; context = { context_ratio; message_count; token_count; max_tokens }
  ; similarity =
      { repetition_risk; goal_alignment; response_alignment; similarity_measurable }
  ; timing =
      { now_ts
      ; idle_seconds
      ; since_last_compaction_sec
      ; since_last_handoff_sec
      ; proactive_warmup_elapsed
      }
  ; failures = { consecutive_hb_failures; consecutive_turn_failures }
  }
;;

let measurement_snapshot_to_json (s : measurement_snapshot) : Yojson.Safe.t =
  `Assoc
    [ "snapshot_id", `String s.snapshot_id
    ; "keeper_name", `String s.keeper_name
    ; "generation", `Int s.generation
    ; "timestamp", `Float s.timestamp
    ; "thresholds", threshold_params_to_json s.thresholds
    ; ( "context"
      , `Assoc
          [ "context_ratio", `Float s.context.context_ratio
          ; "message_count", `Int s.context.message_count
          ; "token_count", `Int s.context.token_count
          ; "max_tokens", `Int s.context.max_tokens
          ] )
    ; ( "similarity"
      , `Assoc
          [ "repetition_risk", `Float s.similarity.repetition_risk
          ; "goal_alignment", `Float s.similarity.goal_alignment
          ; "response_alignment", `Float s.similarity.response_alignment
          ; "similarity_measurable", `Bool s.similarity.similarity_measurable
          ] )
    ; ( "timing"
      , `Assoc
          [ "now_ts", `Float s.timing.now_ts
          ; "idle_seconds", `Int s.timing.idle_seconds
          ; "since_last_compaction_sec", `Float s.timing.since_last_compaction_sec
          ; "since_last_handoff_sec", `Float s.timing.since_last_handoff_sec
          ; "proactive_warmup_elapsed", `Bool s.timing.proactive_warmup_elapsed
          ] )
    ; ( "failures"
      , `Assoc
          [ "consecutive_hb_failures", `Int s.failures.consecutive_hb_failures
          ; "consecutive_turn_failures", `Int s.failures.consecutive_turn_failures
          ] )
    ]
;;
