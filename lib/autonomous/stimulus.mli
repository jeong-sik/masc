(** Stimulus — a single percept that may trigger autonomous action.

    Cycle 23 / Tier B6 — first cut.

    {1 Scope of this PR}

    - {!source} variant of 7 percept categories with [@@deriving tla]
      for symbol-table parity with the architecture spec.
    - {!t} record carrying [id], [source], opaque [payload]
      ([Yojson.Safe.t]), [salience] in [\[0.0, 1.0\]], and a [timestamp].
    - {!make} with salience range validation
      ([Invalid_argument] on violation).
    - {!score} = [salience * exp(-decay * age)] with default
      [decay = 0.01], [age = max 0.0 (now - timestamp)].
    - {!source_to_string} / {!source_of_string} string projections
      (canonical lowercase, dash-free symbols).
    - {!to_json} / {!of_json} for deterministic test assertions and
      future Memory/Checkpoint round-trips. [of_json] returns
      [Result.t] with a human-readable error string.

    {1 Position in the autonomous loop}

    The Perceive sub-phase aggregates [Stimulus.t] values from
    upstream channels (user input, episodic recall, discovery, budget,
    goal lifecycle, priority shifts, opaque external events). The
    Intend sub-phase consumes them via [Intent_engine.analyze]
    (Cycle 24 candidate). [Stimulus] itself has no dependency on the
    rest of the loop — it is a pure value type so it can be unit
    tested without [Eio_main.run] or any keeper context.

    {1 Rationale}

    {2 Why a record (not an object or first-class module)?}

    A record gives a flat, syntactically uniform shape that maps 1:1
    to JSON, matches the [autonomous_KEY_INTERFACES.mli] design
    document, and stays trivially serialisable. The five fields are
    closed and well-known; adding a new field is a deliberate schema
    change, not an implicit extension.

    {2 Why [@@deriving tla] on [source] only?}

    [ppx_tla] in this repo derives symbol tables for plain variants
    (see {!Autonomous_phase.tag}). Records are not currently a
    supported derive target, so {!t} is hand-serialised in
    {!to_json} / {!of_json} instead. The architecture spec
    ([autonomous_KEY_INTERFACES.mli]) places [\[@@deriving tla\]] on
    both [source] and [t]; we follow the codebase's conservative
    pattern and only derive on the variant.

    {2 Why [salience] is not a private float type?}

    Range validation happens once at construction in {!make}.
    Downstream readers can treat [salience] as an opaque
    [\[0.0, 1.0\]] number; introducing a [Salience.t] private type
    is a follow-up Tier consideration, not part of B6.

    {1 Deferred}

    - [Stimulus.t] [@@deriving tla] (record support in [ppx_tla]).
    - Frequency / decay tuning hooks (currently the [decay]
      parameter is module-private with a single default).
    - Cross-stimulus de-duplication (responsibility of the Perceive
      pipeline, not the value type itself). *)

(** {1 Source taxonomy} *)

type source =
  | User_message [@tla.symbol "user_message"]
      (** New user input in the conversation context. *)
  | Memory_recall [@tla.symbol "memory_recall"]
      (** A salient episodic memory has been surfaced. *)
  | Discovery_signal [@tla.symbol "discovery_signal"]
      (** [Proactive_discovery] (later Cycle) found something
          potentially relevant. *)
  | Resource_alert [@tla.symbol "resource_alert"]
      (** A [Resource_budget] threshold has been crossed. *)
  | Goal_phase_change [@tla.symbol "goal_phase_change"]
      (** A tracked goal changed [Goal_phase]. *)
  | Priority_shift [@tla.symbol "priority_shift"]
      (** [Self_priority] re-ranked one or more entries. *)
  | External_event [@tla.symbol "external_event"]
      (** Unstructured event handed in by [Autonomous_bridge]. *)
[@@deriving tla]

(** {1 Stimulus value} *)

type t = {
  id : string;
  source : source;
  payload : Yojson.Safe.t;
  salience : float;  (** in [\[0.0, 1.0\]] *)
  timestamp : float;  (** unix seconds when emitted *)
}

(** {1 Construction} *)

val make :
  id:string ->
  source:source ->
  payload:Yojson.Safe.t ->
  salience:float ->
  timestamp:float ->
  t
(** [make ~id ~source ~payload ~salience ~timestamp] returns a fresh
    stimulus.

    @raise Invalid_argument
      if [salience] is outside [\[0.0, 1.0\]] (NaN included), or if
      [id] is empty. The other fields are passed through verbatim;
      payload validation is the emitter's responsibility. *)

(** {1 Scoring} *)

val score : t -> now:float -> float
(** Time-decayed salience for ranking in the Perceive aggregator.

    [score t ~now = t.salience *. exp (-. decay *. age)] where
    [decay = 0.01] and [age = max 0.0 (now -. t.timestamp)].

    Properties:
    - [score t ~now:t.timestamp = t.salience]
    - [score t ~now] is monotonically non-increasing in [now]
    - [score t ~now < t.timestamp = t.salience] (no time-travel
      amplification) *)

(** {1 String projection} *)

val source_to_string : source -> string
(** Canonical lowercase symbol; equivalent to
    [to_tla_symbol] on {!source}. *)

val source_of_string : string -> source option
(** Inverse of {!source_to_string}. Returns [None] for unknown
    inputs — fail-closed; callers that want
    string-validation-as-error should match on [None] explicitly. *)

(** {1 Serialisation} *)

val to_json : t -> Yojson.Safe.t
(** Render to a fixed-shape JSON object. Keys: [id], [source],
    [payload], [salience], [timestamp]. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Parse a [Stimulus.t] from JSON. The error string identifies the
    first violation (missing key, wrong type, unknown source,
    out-of-range salience). Symmetric with {!to_json}. *)
