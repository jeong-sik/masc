(** Agent_stress -- RFC-0001 Phase 0.2 stress indicator recording.

    Tracks per-agent stress inputs: failure streaks, fallback approval ratios,
    timeout frequency, and rehabilitation state.

    Phase 0.2 records only.  No scheduling or keepalive integration (Gate D).

    Thread-safe via {!Eio.Mutex}.

    @since RFC-0001 Gate A *)

(** Stress event kinds -- each maps to a measurable condition. *)
type stress_kind =
  | Failure_streak of int        (** consecutive failure count *)
  | Turn_failure of turn_failure (** keeper turn ended in an error/partial outcome *)
  | Fallback_approval            (** anti-rat or post-verifier fell back to approve *)
  | Timeout                      (** OAS/LLM call timed out *)
  | Parse_degraded               (** LLM response required fallback parsing *)
  | Task_released                (** agent released a task (gave up) *)

and turn_failure = {
  consecutive : int;             (** persistent turn-failure streak after this turn *)
  threshold : int;               (** crash threshold used for the decision *)
  counted_toward_crash : bool;   (** false for auto-recoverable/transient failures *)
  recoverable : bool;            (** whether keeper can continue without crash escalation *)
  error_kind : string option;    (** coarse sdk error family; never the raw error text *)
}

(** A single stress observation. *)
type event = {
  agent_name : string;
  room_id : string;
  kind : stress_kind;
  timestamp : float;
}

val record : event -> unit
(** Append a stress event.  Thread-safe.  No-op if not initialized. *)

val init : base_path:string -> unit
(** Initialize JSONL store under [base_path/.masc/agent_stress.jsonl].
    Idempotent. *)

val flush : unit -> unit
(** Force flush pending writes. *)

val recent : int -> Yojson.Safe.t list
(** Read the N most recent events as JSON objects. *)

val event_to_json : event -> Yojson.Safe.t
(** Serialize an event for external consumption. *)
