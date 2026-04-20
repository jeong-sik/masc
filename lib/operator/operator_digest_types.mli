(** Operator_digest_types — severity levels, attention items,
    recommended actions, and derived summaries for operator control. *)

(** {1 Severity}

    Closed set — exhaustive matching catches new levels at compile time. *)

type operator_severity = Sev_critical | Sev_bad | Sev_warn

val operator_severity_to_string : operator_severity -> string

(** Strict reverse: raises [Failure _] on unknown input. *)
val operator_severity_of_string : string -> operator_severity

val operator_severity_of_failure_envelope :
  Failure_envelope.severity -> operator_severity

(** {1 Attention item} *)

type attention_item = {
  kind : string;
  severity : operator_severity;
  summary : string;
  target_type : string;
  target_id : string option;
  actor : string option;
  evidence : Yojson.Safe.t;
}

(** {1 Recommended action} *)

type recommended_action = {
  action_type : string;
  target_type : string;
  target_id : string option;
  severity : operator_severity;
  reason : string;
  suggested_payload : Yojson.Safe.t;
}

(** {1 Thresholds and ranking} *)

val stalled_session_threshold_sec : float
val planned_worker_turn_grace_sec : float
val room_digest_session_limit : int

(** [Sev_critical → 3], [Sev_bad → 2], [Sev_warn → 1]. Used for
    descending-severity comparators. *)
val severity_rank : operator_severity -> int

(** Compare attention items: primary by descending severity rank,
    then by [target_id] (None last), then by [kind]. *)
val compare_attention : attention_item -> attention_item -> int

(** Compare recommended actions: same ordering as {!compare_attention}
    but with [action_type] as the final tiebreaker. *)
val compare_recommendation : recommended_action -> recommended_action -> int

(** {1 JSON serialisation} *)

(** Emit with [provenance = "derived"], [authoritative = false]. *)
val attention_item_to_yojson : attention_item -> Yojson.Safe.t

(** [true] if [action_type] requires operator confirmation —
    delegated to {!Operator_approval.confirm_required}. *)
val recommended_confirm_required : string -> bool

(** Emit with preview envelope, [provenance = "fallback"],
    [authoritative = false]. *)
val recommended_action_to_yojson :
  actor:string -> recommended_action -> Yojson.Safe.t

(** {1 Summary builders} *)

(** Sorted count + bad/warn breakdown + top item, JSON-encoded. *)
val summary_of_attention_items : attention_item list -> Yojson.Safe.t

(** Deduplicate by [(action_type, target_type, target_id, normalised reason)]
    keeping the highest-severity representative. *)
val dedup_recommendations : recommended_action list -> recommended_action list

val summary_of_recommendations :
  actor:string -> recommended_action list -> Yojson.Safe.t

(** {1 Target type normalisation} *)

(** [true] for canonical ["root"] and its backward-compat aliases
    ["namespace"] and ["room"]. *)
val is_root_alias : string -> bool

(** Accepts [None] → [Ok "root"]; [Some raw] is trimmed + lowercased, then
    checked via {!is_root_alias}. Otherwise [Error "target_type must be root"]. *)
val normalize_digest_target_type : string option -> (string, string) result
