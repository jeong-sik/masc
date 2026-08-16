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

type run_evidence = {
  captured_at : string;
  harness_git_commit : string option;
  run_id : string;
  keeper_name : string;
  runtime : string option;
      (** Caller-supplied label only; not enforced or verified. *)
  base_path : string;
  endpoint : string;
  turn_interval_s : float;
  facts : Keeper_canary_facts.fact list;
  turns : turn_evidence list;
  recall : recall_evidence;
  timing : timing;
  deterministic_signal : Keeper_canary_facts.score;
  judgment : Keeper_canary_judge.judgment option;
      (** [None] renders as JSON null — no judge ran for this invocation. *)
  notes : string list;
}

val to_yojson : run_evidence -> Yojson.Safe.t
val to_pretty_string : run_evidence -> string
