(** Thompson Sampling — per-agent Beta-prior bookkeeping.

    Maintains per-agent Beta(alpha, beta) priors fed by vote and quality
    feedback, persisted across restarts.  The selection engine that once
    consumed these priors was removed as production-unreachable
    (2026-07-21 dead-surface audit); the priors stay live as the
    reputation/confidence source for dashboard and board surfaces. *)

type quality_verdict =
  | Pass
  | Warn of string
  | Fail of string

(** {1 Types} *)

(** Agent statistics for Thompson Sampling.
    Alpha/beta are Beta distribution priors, updated by vote feedback. *)
type agent_stats = {
  name : string;
  (* Thompson Sampling Beta distribution parameters *)
  mutable alpha : float;  (** Beta prior: 1.0 + successes, min 0.1 *)
  mutable beta : float;   (** Beta prior: 1.0 + failures, min 0.1 *)
  (* Selection tracking *)
  mutable selections : int;
  mutable last_selected_at : float;  (** Unix timestamp for restart resilience *)
  (* Quality metrics *)
  mutable total_votes_up : int;
  mutable total_votes_down : int;
  mutable posts_created : int;
  mutable comments_created : int;
  mutable skips : int;
  (* Timestamp *)
  mutable updated_at : float;
}

(** {1 Configuration} *)

(** Set base path for stats storage (cluster root, e.g. ~/me).
    Call during server initialization before any stats operations. *)
val set_base_path : string -> unit

(** {1 Statistics Management} *)

(** Get stats for an agent, creating default if not exists *)
val get_stats : string -> agent_stats

(** Get all agent stats *)
val get_all_stats : unit -> agent_stats list

(** {1 Feedback Updates} *)

(** Record a vote on agent content.
    Called from Board.vote after successful vote.
    Votes batch in memory and reach disk via the pending-vote overlay in
    [save_stats]; the live table reflects them after the next
    [load_stats]. *)
val record_vote :
  agent_name:string ->
  direction:[`Up | `Down] ->
  unit

(** Record agent action (post/comment/skip) *)
val record_action :
  agent_name:string ->
  action:[`Post | `Comment | `Skip] ->
  unit

(** Record a quality signal into Thompson α/β.
    Pass → α +0.3 (reward), Warn → β +0.1 (mild penalty), Fail → β +0.5 (penalty). *)
val record_quality_signal :
  agent_name:string ->
  verdict:quality_verdict ->
  unit

(** {1 Persistence} *)

(** Load stats from persistent storage (.masc/autonomy_stats.jsonl) *)
val load_stats : unit -> unit

(** Save stats to persistent storage *)
val save_stats : unit -> unit
