(** MASC Level 2 Configuration - Externalized Constants

    MAGI Recommendation: Externalize hardcoded constants for runtime tuning.

    Environment variables:
    - MASC_DRIFT_THRESHOLD: Drift detection threshold (default: 0.85)
    - MASC_LOCK_WARN_MS: Lock contention warning threshold in ms (default: 100)
    - MASC_HEBBIAN_RATE: Symmetric Hebbian learning rate (default: 0.075)
*)

(** Drift guard configuration *)
module Drift_guard = struct
  let default_threshold () =
    Env_config_core.get_float ~default:0.85 "MASC_DRIFT_THRESHOLD"

  (** Similarity weights for Jaccard/Cosine combination *)
  type weights = { jaccard: float; cosine: float }
  let weights () = {
    jaccard = Env_config_core.get_float ~default:0.4 "MASC_DRIFT_JACCARD_WEIGHT";
    cosine = Env_config_core.get_float ~default:0.6 "MASC_DRIFT_COSINE_WEIGHT";
  }
end

(** Lock configuration *)
module Lock = struct
  let warn_threshold_ms () =
    Env_config_core.get_float ~default:100.0 "MASC_LOCK_WARN_MS"
end

(** Hebbian learning configuration *)
module Hebbian = struct
  let learning_rate () =
    Env_config_core.get_float ~default:0.075 "MASC_HEBBIAN_RATE"
  let decay_rate () =
    Env_config_core.get_float ~default:0.01 "MASC_HEBBIAN_DECAY"
  let min_weight () = 0.05
  let max_weight () = 1.0
end

(** Get all config as JSON for debugging *)
let to_json () : Yojson.Safe.t =
  `Assoc [
    ("drift_threshold", `Float (Drift_guard.default_threshold ()));
    ("lock_warn_ms", `Float (Lock.warn_threshold_ms ()));
    ("hebbian_rate", `Float (Hebbian.learning_rate ()));
    ("hebbian_decay", `Float (Hebbian.decay_rate ()));
  ]

(** Print config to stderr for debugging *)
let print_config () =
  Log.Level2.info "Configuration:";
  Log.Level2.info "  MASC_DRIFT_THRESHOLD=%.2f" (Drift_guard.default_threshold ());
  Log.Level2.info "  MASC_LOCK_WARN_MS=%.0f" (Lock.warn_threshold_ms ());
  Log.Level2.info "  MASC_HEBBIAN_RATE=%.3f" (Hebbian.learning_rate ())
