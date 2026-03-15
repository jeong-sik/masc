(** Agent_reputation — Reputation scoring from existing JSONL data

    Computes agent reputation from task transitions, mention inbox,
    board posts/comments, and debate participation.
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
  debates_participated: int;
  overall_score: float;       (** Weighted composite 0.0-1.0 *)
}

val default_reputation : agent_name:string -> agent_reputation
(** A zero-valued reputation for a given agent. *)

val compute_reputation : Room.config -> agent_name:string -> agent_reputation
(** Compute reputation by reading tasks, mentions, board, and debate data. *)

val reputation_to_json : agent_reputation -> Yojson.Safe.t
(** Serialize reputation to JSON. *)

val reputation_of_json : Yojson.Safe.t -> agent_reputation option
(** Deserialize reputation from JSON. Returns None on parse failure. *)

val compute_overall_score :
  completion_rate:float ->
  response_rate:float ->
  board_posts:int ->
  board_comments:int ->
  debates_participated:int ->
  float
(** Compute the weighted overall score from individual metrics.
    Exposed for testing. *)
