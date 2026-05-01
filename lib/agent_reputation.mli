(** Agent_reputation — Reputation scoring from existing JSONL data

    Computes agent reputation from task transitions, mention inbox,
    and board posts/comments.
    No new storage — reads from existing `.masc/` JSONL files.

    @since Phase 3B — Keeper Deliberation Engine
*)

(** Agent reputation record with all metrics and a composite score. *)
type agent_reputation = {
  agent_name: string;
  tasks_completed: int;
  tasks_claimed: int;
  completion_rate: float;     (** completed / claimed, 0.0 if no claims *)
  mentions_received: int;
  mentions_responded: int;
  response_rate: float;       (** responded / received, 0.0 if no mentions *)
  board_posts: int;
  board_comments: int;
  accountability_score: float; (** Evidence-backed trust modifier, 0.0-1.0 *)
  accountability_risk_band: string; (** low | medium | high from the accountability ledger *)
  accountability_evidence_coverage: float;
  accountability_unsupported_completion_rate: float;
  accountability_open_overdue_commitments: int;
  accountability_keeper_name: string; (** Keeper identity used for accountability lookup. *)
  accountability_source: string; (** direct_agent | canonical_keeper_fallback | none *)
  accountability_source_label: string; (** Operator-facing provenance label. *)
  overall_score: float;       (** Weighted composite after accountability penalty, 0.0-1.0 *)
  (* v2 multi-dimensional scores *)
  execution_reliability: float;
  (** Tool-call success rate from the v2 reputation ledger. 0.0–1.0.
      Defaults to 1.0 when no v2 ledger events exist. *)
  goal_adherence: float;
  (** Proportion of completed goals that were on-topic and within budget. 0.0–1.0.
      Defaults to 1.0 when no v2 ledger events exist. *)
  safety_compliance: float;
  (** Penalty-adjusted safety score; decreases with sandbox violations. 0.0–1.0.
      Defaults to 1.0 when no v2 ledger events exist. *)
  autonomy_level: string;
  (** Derived operational envelope: "restricted" | "standard" | "elevated" | "full".
      Advisory only until calibration Phase 5 is complete. *)
}

val agent_reputation_to_yojson : agent_reputation -> Yojson.Safe.t
(** PPX-generated serializer. *)

val agent_reputation_of_yojson :
  Yojson.Safe.t -> (agent_reputation, string) result
(** PPX-generated deserializer.  Returns [Error msg] on parse failure. *)

val default_reputation : agent_name:string -> agent_reputation
(** A zero-valued reputation for a given agent. *)

val compute_reputation : Coord.config -> agent_name:string -> agent_reputation
(** Compute reputation by reading tasks, mentions, and board data. *)

val reputation_to_json : agent_reputation -> Yojson.Safe.t
(** Alias for {!agent_reputation_to_yojson}. *)

val reputation_of_json : Yojson.Safe.t -> agent_reputation option
(** Wraps {!agent_reputation_of_yojson}. Returns None on parse failure
    or when [agent_name] is empty. *)

val compute_accountability_score :
  evidence_coverage:float ->
  unsupported_completion_rate:float ->
  open_overdue_commitments:int ->
  float
(** Compute an evidence-backed penalty score from accountability metrics.
    A score of [1.0] means no penalty; [0.0] means the agent's activity
    score should not be trusted for routing/reward decisions. *)

val compute_overall_score :
  completion_rate:float ->
  response_rate:float ->
  board_posts:int ->
  board_comments:int ->
  float
(** Compute the weighted overall score from individual metrics.
    Exposed for testing. *)
