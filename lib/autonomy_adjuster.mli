(** Autonomy Adjuster — Feedback Closure for Agent Selection (Phase 4).

    Observes accumulated quality signals from agents (Thompson Sampling
    stats from {!Thompson_sampling} and health status from {!Agent_health}) and
    automatically adjusts per-agent autonomy levels.

    Autonomy level is a continuous float in [0.0, 1.0], default 0.5.
    Higher values grant agents more autonomous action; lower values
    require supervision or suspend the agent.

    Algorithm:
    - quality_ratio = alpha / (alpha + beta)  (Thompson Sampling posterior mean)
    - High quality (>0.7): +0.05 per tick
    - Medium quality (0.4-0.7): maintain
    - Low quality (<0.4): -0.1 per tick  (penalize faster than reward)
    - Unhealthy agent: floor at 0.0
    - Recovering agent: cap at 0.5

    Persistence: JSONL at [.masc/lodge_autonomy.jsonl].

    @since 2.77.0 *)

(** {1 Types} *)

(** Discrete action classification derived from continuous autonomy level. *)
type action_class =
  | Autonomous   (** >= 0.8: agent acts without supervision *)
  | Supervised   (** 0.5 ..< 0.8: agent proposes, human/system approves *)
  | Restricted   (** 0.2 ..< 0.5: limited action set *)
  | Suspended    (** < 0.2: no autonomous action allowed *)

(** Per-agent autonomy record. *)
type autonomy_record = {
  agent_name : string;
  level : float;            (** [0.0, 1.0] *)
  action_class : action_class;
  quality_ratio : float;    (** last observed alpha / (alpha + beta) *)
  updated_at : float;       (** Unix timestamp *)
}

(** {1 Configuration} *)

(** Set the base path for persistence (defaults to MASC_BASE_PATH or ".masc"). *)
val set_base_path : string -> unit

(** {1 Core API} *)

(** Look up the current autonomy record for an agent.
    Returns a default record (level 0.5, Supervised) if not yet tracked. *)
val get_autonomy : agent_name:string -> autonomy_record

(** Perform one adjustment tick for an agent.
    Reads Thompson Sampling stats from {!Thompson_sampling} and health status
    from {!Agent_health}, then adjusts the autonomy level accordingly.
    Returns the updated record and persists to JSONL. *)
val adjust : agent_name:string -> autonomy_record

(** Convenience: check whether an agent may act autonomously.
    Equivalent to [(get_autonomy ~agent_name).action_class = Autonomous]. *)
val check_autonomy : agent_name:string -> action_class

(** {1 Batch Operations} *)

(** Return all tracked autonomy records. *)
val get_all : unit -> autonomy_record list

(** Reset an agent's autonomy to the given level (default 0.5).
    Useful for manual intervention. *)
val reset : agent_name:string -> ?level:float -> unit -> autonomy_record

(** {1 Serialization} *)

val autonomy_record_to_yojson : autonomy_record -> Yojson.Safe.t
val autonomy_record_of_yojson : Yojson.Safe.t -> (autonomy_record, string) result
val action_class_to_string : action_class -> string
