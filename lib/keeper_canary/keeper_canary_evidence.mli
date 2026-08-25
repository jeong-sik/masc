(** Schema'd evidence JSON for the keeper canary harness.

    [schema_version] is ["masc.keeper_canary_run.v1"], distinct from
    docs/evidence/keeper-multiturn-*.json's
    ["masc.keeper_feature_matrix.multiturn_evidence.v1"] — see the .ml doc
    comment for why this is a new schema rather than a reshape.

    [judgment] is [`Null] unless an LLM judge ran (bin's [--judge-runtime]):
    the pass/fail call on whether the recall reply demonstrates real
    continuity belongs to that judge, not this harness's own substring
    check — see {!Keeper_canary_facts.score} for that raw signal instead. *)

val schema_version : string

type turn_evidence = {
  index : int;
  category : string option;
      (** The fact category this turn established, or [None] for the
          recall turn. *)
  delivery_key : Yojson.Safe.t option;
      (** [Keeper_chat_delivery_identity.delivery_key_to_yojson] as read
          back from the durable transcript row this turn produced. [None]
          when no row could be correlated to this turn's request id. *)
  turn_ref : string option;
      (** [Ids.Turn_ref.to_string] from the same durable row. *)
  sent_at : string;  (** ISO8601, client-observed send time. *)
  round_trip_s : float;
      (** Wall-clock seconds from send to a parsed HTTP reply. *)
  reply_digest : string option;
      (** SHA-256 hex of the assistant reply's content, or [None] when no
          reply row was found for this turn. *)
}

type recall_evidence = {
  turn_index : int;
  request_id : string;
  prompt : string;
  reply : string;  (** Raw recall reply text, not a digest. *)
}

type timing = { min_s : float; median_s : float; max_s : float }

val timing_of : float list -> timing
(** [min_s]/[median_s]/[max_s] over a list of per-turn round-trip seconds.
    [{ min_s = 0.; median_s = 0.; max_s = 0. }] on the empty list — there is
    no turn to time, not an error. Even-length lists average the two
    middle values for the median. *)

type restart_injection = {
  after_turn : int;  (** The 1-indexed turn this injection ran after. *)
  started_at : string;  (** ISO8601, client-observed. *)
  duration_s : float;
      (** Wall-clock seconds the whole injection sequence took. *)
  trace_id_before : string;
  trace_id_after : string;
  generation_before : int;
  generation_after : int;
}

type failover_injection = {
  after_turn : int;
  started_at : string;
  duration_s : float;  (** Wall-clock seconds the down command took. *)
  down_cmd : string;
  up_cmd : string option;
  window_start : string;
      (** Manifest rows at or after this instant were classified. *)
  mode : Keeper_canary_failover.mode;
  attempts : Keeper_canary_failover.attempt list;
      (** The exact rows the mode verdict was computed from. *)
}

type injection =
  | Restart of restart_injection
  | Failover of failover_injection
      (** Closed axis — a new injection kind is a new constructor, and the
          serializer's exhaustive match forces every reader decision at
          compile time. *)

val restart_is_continuation : restart_injection -> bool
(** True when trace identity survived the injection — same trace_id and
    same generation is the signal the 08-14 drain-restart canary
    established for "continuation restart, not a reset". *)

type run_evidence = {
  captured_at : string;
  harness_git_commit : string option;
      (** Build-time commit embedded in the canary executable.  This is not
          the HEAD of a checkout from which the packaged binary is invoked. *)
  run_id : string;
  keeper_name : string;
  runtime : string option;
      (** Caller-supplied label only; not enforced or verified. *)
  base_path : string;
  endpoint : string;
  turn_interval_s : float;
      (** The effective per-gap interval the run used (derived from the
          wall-clock target when one was given). *)
  wall_clock_target_s : float option;
      (** [None] renders as JSON null — no wall-clock target was set. *)
  facts : Keeper_canary_facts.fact list;
  turns : turn_evidence list;
  recall : recall_evidence;
  timing : timing;
  deterministic_signal : Keeper_canary_facts.score;
  judgment : Keeper_canary_judge.judgment option;
      (** [None] renders as JSON null — no judge ran for this invocation. *)
  injections : injection list;
      (** Empty when the run injected nothing; order follows execution. *)
  serving : Keeper_canary_serving.check option;
      (** [None] renders as JSON null — no [--expect-runtime] was given, so
          the run makes no claim about who served its turns. [runtime]
          above stays a caller-supplied label; this field is the verified
          counterpart (#28913). *)
  notes : string list;
}

val to_yojson : run_evidence -> Yojson.Safe.t
val to_pretty_string : run_evidence -> string
