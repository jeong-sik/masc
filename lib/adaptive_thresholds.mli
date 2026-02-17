(** Adaptive Thresholds — EMA-based threshold learning from handoff outcomes

    Safety bounds: 0.20 <= prepare < handoff <= 0.95, min gap 0.15
    Persistence: ~/.masc/adaptive_thresholds_{room}.json
    Fallback chain: adaptive (if enabled+available) -> env var -> defaults *)

(** Threshold pair *)
type thresholds = {
  prepare : float;  (** context usage % to start preparing *)
  handoff : float;  (** context usage % to trigger handoff *)
}

(** Persisted state for a room *)
type adaptive_state = {
  thresholds : thresholds;
  session_count : int;
  cumulative_delta : float;  (** total adjustment this session *)
  last_updated : string;     (** ISO 8601 timestamp *)
}

(** Default thresholds: prepare=0.50, handoff=0.80 *)
val default_thresholds : thresholds

(** Minimum prepare threshold *)
val min_prepare : float

(** Maximum handoff threshold *)
val max_handoff : float

(** Minimum gap between prepare and handoff *)
val min_gap : float

(** Clamp thresholds to safety bounds *)
val clamp_thresholds : thresholds -> thresholds

(** Create initial adaptive state with default thresholds *)
val initial_state : unit -> adaptive_state

(** Apply a handoff outcome to adapt thresholds.
    Adjusts handoff threshold based on outcome quality signals,
    prepare tracks proportionally. Respects session delta cap. *)
val adapt : adaptive_state -> Handoff_quality.handoff_outcome -> adaptive_state

(** Serialize adaptive_state to JSON *)
val state_to_json : adaptive_state -> Yojson.Safe.t

(** Deserialize adaptive_state from JSON *)
val state_of_json : Yojson.Safe.t -> adaptive_state option

(** Path to persistence file for a given room *)
val state_file_path : room:string -> string

(** Save state to ~/.masc/adaptive_thresholds_{room}.json *)
val save_state : room:string -> adaptive_state -> unit

(** Load state from persistence, None if not found or invalid *)
val load_state : room:string -> adaptive_state option

(** Get effective thresholds with fallback chain:
    adaptive -> env var -> defaults *)
val get_effective_thresholds : enabled:bool -> room:string -> thresholds
