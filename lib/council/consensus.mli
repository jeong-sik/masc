(** Consensus - Multi-agent voting and agreement system *)

(** {1 Types} *)

(** Decision type for voting *)
type decision =
  | Approve
  | Reject
  | Abstain

(** Individual vote record *)
type vote = {
  agent: string;
  decision: decision;
  reason: string;
  timestamp: float;
}

(** Voting result *)
type voting_result =
  | Unanimous of decision      (** All voters agreed *)
  | Majority of int            (** Majority reached with vote count *)
  | Deadlock                   (** No clear majority *)
  | Escalate                   (** Requires higher authority *)

(** Voting session state *)
type voting_state =
  | Open
  | Closed
  | Cancelled

(** Voting session *)
type session = {
  id: string;
  topic: string;
  initiator: string;
  votes: vote list;
  quorum: int;                 (** Minimum required votes *)
  threshold: float;            (** Majority threshold (0.0-1.0) *)
  state: voting_state;
  created_at: float;
  closed_at: float option;
}

(** Voting error types *)
type error =
  | Session_not_found of string
  | Session_closed of string
  | Already_voted of string
  | Quorum_not_met of { required: int; current: int }
  | Invalid_threshold of float

(** {1 Core Functions} *)

(** Start a new voting session.
    @param topic The topic to vote on
    @param initiator The agent starting the vote
    @param quorum Minimum number of votes required (default: 2)
    @param threshold Ratio needed for majority (default: 0.5) *)
val start_voting : 
  topic:string -> 
  initiator:string -> 
  ?quorum:int -> 
  ?threshold:float -> 
  unit -> 
  (session, error) Result.t

(** Cast a vote in a session.
    @param session_id The voting session ID
    @param agent The voting agent's name
    @param decision Approve, Reject, or Abstain
    @param reason Explanation for the decision *)
val cast_vote : 
  session_id:string -> 
  agent:string -> 
  decision:decision -> 
  reason:string -> 
  (session, error) Result.t

(** Tally votes and return (approves, rejects, abstains) *)
val tally_votes : session -> (int * int * int)

(** Get voting result. Fails if quorum not met. *)
val get_result : session_id:string -> (voting_result, error) Result.t

(** {1 Session Management} *)

(** Close a voting session *)
val close_session : session_id:string -> (session, error) Result.t

(** Cancel a voting session *)
val cancel_session : session_id:string -> (session, error) Result.t

(** Get session by ID *)
val get_session : session_id:string -> session option

(** List all active (open) sessions *)
val list_active_sessions : unit -> session list

(** Check if quorum is met for a session *)
val quorum_met : session -> bool

(** Clear all sessions (for testing) *)
val clear_sessions : unit -> unit

(** {1 JSON Serialization} *)

val decision_to_yojson : decision -> Yojson.Safe.t
val decision_of_yojson : Yojson.Safe.t -> (decision, string) Result.t
val vote_to_yojson : vote -> Yojson.Safe.t
val vote_of_yojson : Yojson.Safe.t -> (vote, string) Result.t
val voting_result_to_yojson : voting_result -> Yojson.Safe.t
val voting_result_of_yojson : Yojson.Safe.t -> (voting_result, string) Result.t
val voting_state_to_yojson : voting_state -> Yojson.Safe.t
val voting_state_of_yojson : Yojson.Safe.t -> (voting_state, string) Result.t

val session_to_json : session -> Yojson.Safe.t
val voting_result_to_json : voting_result -> Yojson.Safe.t
