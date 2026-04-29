(** Hebbian_eio — Hebbian learning of agent collaboration patterns.

    "Agents that fire together, wire together."  Tracks synapses
    between agent pairs:

    - Successful collaborations strengthen the synapse weight.
    - Failed collaborations weaken it.
    - Periodic consolidation decays old / unused synapses and
      prunes those below [min_weight].

    Storage: JSON at \[<masc_dir>/synapses/graph.json\] with
    file-lock-protected reads/writes.

    Pure synchronous module despite the [_eio] suffix — uses
    {!Eio_guard.run_in_systhread} for blocking I/O.

    Internal: ~12 helpers stay private — file path builders,
    [run_blocking_op], the lock primitives ([cas_float],
    [with_graph_lock]), [ensure_synapses_dir], lock-stat
    Atomic.t state, and [save_graph] (writes are mediated by
    [with_graph_lock] in {!strengthen} / {!weaken} /
    {!consolidate}). *)

(** {1 Types} *)

type config = Coord_utils.config

type synapse = {
  from_agent : string;
  to_agent : string;
  weight : float;  (** [\[0.0, 1.0\]] — higher = stronger. *)
  success_count : int;
  failure_count : int;
  last_updated : float;  (** Unix timestamp. *)
  created_at : float;
  weight_history : (float * float) list;
      (** Capped at {!history_cap}.  Newest first.  Used by
          dashboard sparklines to visualise learning direction. *)
}

type synapse_graph = {
  synapses : synapse list;
  last_consolidation : float;
}

type learning_params = {
  strengthen_rate : float;  (** Default 0.1. *)
  weaken_rate : float;  (** Default 0.05. *)
  decay_rate : float;  (** Daily decay rate. *)
  min_weight : float;  (** Prune threshold. *)
  max_weight : float;
}

(** {1 Constants} *)

val history_cap : int
(** [30].  Cap for {!synapse.weight_history}.  Newer entries
    evict older ones.  Picked to match dashboard sparkline pixel
    budget (80 px / ~2.7 px per point); the rationale came after
    the number — raise if longer trajectories are needed (JSON
    payload grows linearly). *)

val edge_update_outcome_metric : string
(** Pinned literal: ["masc_hebbian_edge_update_total"].  Prometheus
    counter incremented by {!strengthen} / {!weaken} with
    [outcome] label (e.g. ["weaken_no_synapse"], ["strengthen_existing"]). *)

(** {1 Defaults} *)

val default_params : unit -> learning_params
(** [default_params ()] reads {!Level2_config.Hebbian} env values
    at call time and returns a fresh record.  Symmetric
    [strengthen_rate = weaken_rate]. *)

(** {1 Helpers (test-visible)} *)

val append_history :
  ts:float -> w:float -> (float * float) list -> (float * float) list
(** [append_history ~ts ~w history] prepends [(ts, w)] and trims
    to {!history_cap}.  Same fractional tick produces separate
    entries — preserves trajectory resolution and keeps append
    deterministic regardless of clock granularity. *)

(** {1 JSON round-trip} *)

val synapse_to_json : synapse -> Yojson.Safe.t
val synapse_of_json : Yojson.Safe.t -> synapse option
val graph_to_json : synapse_graph -> Yojson.Safe.t
val graph_of_json : Yojson.Safe.t -> synapse_graph

(** {1 Persistence} *)

val load_graph : config -> synapse_graph
(** [load_graph config] reads the graph JSON.  Returns an empty
    graph (no synapses, [last_consolidation = 0.0]) when the file
    does not exist. *)

(** {1 Learning operations}

    All learning operations acquire the graph lock + persist on
    success.  [outcome] label on the Prometheus counter
    differentiates "synapse already existed and was updated" from
    "synapse created" / "synapse pruned below min_weight" cases. *)

val strengthen :
  config ->
  ?params:learning_params ->
  from_agent:string ->
  to_agent:string ->
  unit ->
  unit
(** [strengthen config ?params ~from_agent ~to_agent ()]
    increments [success_count] and increases [weight] by
    [params.strengthen_rate], capped at [params.max_weight]. *)

val weaken :
  config ->
  ?params:learning_params ->
  from_agent:string ->
  to_agent:string ->
  unit ->
  unit
(** [weaken config ?params ~from_agent ~to_agent ()] increments
    [failure_count] and decreases [weight] by [params.weaken_rate],
    floored at [params.min_weight] (synapses falling below are
    pruned during {!consolidate}). *)

(** {1 Consolidation} *)

val consolidate :
  config ->
  ?params:learning_params ->
  decay_after_days:int ->
  unit ->
  int
(** [consolidate config ?params ~decay_after_days ()] applies
    [params.decay_rate] to synapses whose [last_updated] is older
    than [decay_after_days].  Prunes synapses whose [weight] falls
    below [params.min_weight].  Returns the number pruned. *)

val run_consolidation_once :
  config -> decay_after_days:int -> unit
(** [run_consolidation_once config ~decay_after_days] is a wrapper
    that calls {!consolidate}, increments
    \["masc_hebbian_consolidate_total"\] with timing labels, and
    swallows exceptions (logs warning).  Used by the consolidation
    fiber. *)

val start_consolidation_fiber :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  config ->
  unit
(** [start_consolidation_fiber ~sw ~clock config] runs an
    infinite loop calling {!run_consolidation_once} every
    [Level2_config.Hebbian.consolidation_interval_s ()] seconds.
    Reads the env values at fiber start (not on every iteration)
    so changes require fiber restart. *)

(** {1 Queries} *)

val get_preferred_partner :
  config -> agent_id:string -> string option
(** [get_preferred_partner config ~agent_id] returns the
    [to_agent] of the strongest outgoing synapse from [agent_id],
    or [None] when no outgoing synapses exist. *)

val get_graph_data : config -> synapse list * string list
(** [get_graph_data config] returns [(synapses, agent_ids)] where
    [agent_ids] is the sorted-unique union of [from_agent] and
    [to_agent] across all synapses.  Used by dashboard graph
    rendering. *)

(** {1 Lock statistics (operator-visible)} *)

val get_lock_stats : unit -> int * float * float
(** [get_lock_stats ()] returns
    [(acquisitions, avg_wait_ms, max_wait_ms)] since the last
    {!reset_lock_stats}.  Used by the dashboard concurrency
    metrics. *)

val reset_lock_stats : unit -> unit
(** [reset_lock_stats ()] zeroes all 3 lock-stat counters. *)
