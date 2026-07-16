(** Keeper Measurement — Det/NonDet Boundary Types (RFC-0002).
    Phase 1: types and serialization.
    Phase 4: pure [capture] function. *)

type context_measurement = {
  context_ratio : float;
  message_count : int;
  token_count : int;
  max_tokens : int;
}

type timing_measurement = {
  now_ts : float;
  idle_seconds : int;
  since_last_compaction_sec : float;
  proactive_warmup_elapsed : bool;
}

type failure_measurement = {
  consecutive_hb_failures : int;
  consecutive_turn_failures : int;
}

type measurement_snapshot = {
  snapshot_id : string;
  keeper_name : string;
  generation : int;
  timestamp : float;
  context : context_measurement;
  timing : timing_measurement;
  failures : failure_measurement;
}

let capture
      ~snapshot_id
      ~keeper_name
      ~generation
      ~timestamp
      ~context_ratio
      ~message_count
      ~token_count
      ~max_tokens
      ~now_ts
      ~idle_seconds
      ~since_last_compaction_sec
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
  ; context =
      { context_ratio
      ; message_count
      ; token_count
      ; max_tokens
      }
  ; timing =
      { now_ts
      ; idle_seconds
      ; since_last_compaction_sec
      ; proactive_warmup_elapsed
      }
  ; failures =
      { consecutive_hb_failures
      ; consecutive_turn_failures
      }
  }

let measurement_snapshot_to_json (s : measurement_snapshot) : Yojson.Safe.t =
  `Assoc [
    "snapshot_id", `String s.snapshot_id;
    "keeper_name", `String s.keeper_name;
    "generation", `Int s.generation;
    "timestamp", `Float s.timestamp;
    "context", `Assoc [
      "context_ratio", `Float s.context.context_ratio;
      "message_count", `Int s.context.message_count;
      "token_count", `Int s.context.token_count;
      "max_tokens", `Int s.context.max_tokens;
    ];
    "timing", `Assoc [
      "now_ts", `Float s.timing.now_ts;
      "idle_seconds", `Int s.timing.idle_seconds;
      "since_last_compaction_sec", `Float s.timing.since_last_compaction_sec;
      "proactive_warmup_elapsed", `Bool s.timing.proactive_warmup_elapsed;
    ];
    "failures", `Assoc [
      "consecutive_hb_failures", `Int s.failures.consecutive_hb_failures;
      "consecutive_turn_failures", `Int s.failures.consecutive_turn_failures;
    ];
  ]
