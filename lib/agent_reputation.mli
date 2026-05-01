open Base
module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float
module Random = Stdlib.Random

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
}

val agent_reputation_to_yojson : agent_reputation -> Yojson.Safe.t
(** PPX-generated serializer. *)

val agent_reputation_of_yojson :
  Yojson.Safe.t -> (agent_reputation, string) Result.t
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
