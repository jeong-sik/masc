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
  overall_score: float;       (** Weighted composite 0.0-1.0 *)
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

val compute_overall_score :
  completion_rate:float ->
  response_rate:float ->
  board_posts:int ->
  board_comments:int ->
  float
(** Compute the weighted overall score from individual metrics.
    Exposed for testing. *)
