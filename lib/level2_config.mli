(** Level2_config — externalised tuning constants for MASC's
    Level 2 cognitive subsystems (drift guard, lock contention,
    Hebbian learning).

    Every value is a thunk that re-reads the corresponding env
    var at call time; callers should treat reads as cheap but not
    pinning a value once at startup is intentional — it lets
    operators change a constant by setting an env var and bouncing
    the process group without a code patch.

    Recognised env vars:
    - [MASC_DRIFT_THRESHOLD]            — drift detection threshold (default 0.85)
    - [MASC_DRIFT_JACCARD_WEIGHT]       — Jaccard weight in similarity blend (default 0.4)
    - [MASC_DRIFT_COSINE_WEIGHT]        — Cosine weight in similarity blend (default 0.6)
    - [MASC_LOCK_WARN_MS]               — lock contention warning threshold ms (default 100)
    - [MASC_HEBBIAN_RATE]               — symmetric Hebbian learning rate (default 0.075)
    - [MASC_HEBBIAN_DECAY]              — Hebbian decay rate (default 0.01)
    - [MASC_HEBBIAN_CONSOLIDATION_INTERVAL_S] — consolidation cadence s (default 3600)
    - [MASC_HEBBIAN_DECAY_AFTER_DAYS]   — synapse decay horizon days (default 14) *)

(** {1 Drift guard} *)

module Drift_guard : sig
  type weights = { jaccard : float; cosine : float }
  (** Blend weights for the Jaccard / Cosine similarity combiner. *)

  val default_threshold : unit -> float
  (** [MASC_DRIFT_THRESHOLD], default 0.85. *)

  val weights : unit -> weights
  (** [MASC_DRIFT_JACCARD_WEIGHT] / [MASC_DRIFT_COSINE_WEIGHT],
      defaults 0.4 / 0.6. *)
end

(** {1 Lock contention} *)

module Lock : sig
  val warn_threshold_ms : unit -> float
  (** [MASC_LOCK_WARN_MS], default 100.0 ms. *)
end

(** {1 Hebbian learning} *)

module Hebbian : sig
  val learning_rate : unit -> float
  (** [MASC_HEBBIAN_RATE], default 0.075. Used symmetrically for
      strengthen / weaken. *)

  val decay_rate : unit -> float
  (** [MASC_HEBBIAN_DECAY], default 0.01. *)

  val min_weight : unit -> float
  (** Lower bound on synapse weight, currently 0.05 (constant). *)

  val max_weight : unit -> float
  (** Upper bound on synapse weight, currently 1.0 (constant). *)

  val consolidation_interval_s : unit -> float
  (** [MASC_HEBBIAN_CONSOLIDATION_INTERVAL_S], default 3600.0 s.
      Issue #9876 — cadence kept much shorter than the decay
      horizon so consolidation never races with active
      strengthen / weaken traffic (~336 passes per decay window
      at the defaults). *)

  val decay_after_days : unit -> float
  (** [MASC_HEBBIAN_DECAY_AFTER_DAYS], default 14.0 days. *)
end

(** {1 Inspection} *)

val to_json : unit -> Yojson.Safe.t
(** Snapshot the four headline constants
    ([drift_threshold] / [lock_warn_ms] / [hebbian_rate] /
    [hebbian_decay]) as a JSON object for dashboards. *)

val print_config : unit -> unit
(** Log the headline constants to [Log.Level2.info] for boot-time
    debugging. *)
