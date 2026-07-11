(** Operator_judgment — operator-level judgment records persisted
    to [<masc_dir>/operator/judgments.jsonl].

    A judgment captures one operator-level decision (currently:
    workspace-level scope decisions) with provenance, freshness
    window, supersedes-chain, confidence, evidence refs, and
    optional recommended-action JSON.

    Two read paths: {!latest_active} (typed record) and
    {!latest_active_json} (JSON envelope).  One write path:
    {!record}, which auto-chains supersedes by reading the
    current latest before append. *)

(** {1 Types} *)

type target_type = Workspace
(** Currently a single constructor.  Closed variant — adding a
    second target (e.g. [Keeper]) must extend
    {!target_type_to_string} / {!target_type_of_string}
    explicitly so the JSONL on-disk format remains
    backward-compatible. *)

type record = {
  judgment_id : string;
  surface : string;
  target_type : target_type;
  target_id : string option;
  status : string;
  summary : string;
  confidence : float;
  generated_at : string;
  generated_at_unix : float;
  fresh_until : string;
  fresh_until_unix : float;
  keeper_name : string;
  model_name : string option;
  runtime_name : string option;
  evidence_refs : string list;
  recommended_action : Yojson.Safe.t option;
  supersedes : string list;
  fallback_used : bool;
  disagreement_with_truth : bool;
}
(** Concrete record because consumers
    ({!Operator_control_action}, {!Dashboard_operator_judge},
    {!test_operator_control_judgment}) field-access the record
    when projecting to JSON or checking specific fields.  All
    19 fields are part of the on-disk JSONL contract — drift
    requires synchronized migration. *)

(** {1 target_type codec} *)

val target_type_to_string : target_type -> string
(** [Workspace -> "workspace"].  Pinned literal for the on-disk JSONL format. *)

val target_type_of_string : string -> target_type option
(** Accepts only the canonical [["workspace"]] target type for [Workspace].
    Historical [["root"]] / [["namespace"]] aliases are rejected at the parse
    boundary. *)

(** {1 JSON codec} *)

val to_yojson : record -> Yojson.Safe.t
(** Renders the 20-field JSON object (19 record fields +
    [["provenance": "judgment"]] tag).  The provenance literal
    is pinned — dashboard consumers grep on it to distinguish
    judgment posts from other JSONL records. *)

val of_yojson : Yojson.Safe.t -> (record, string) result
(** Parses the JSON object back to a record.  Fail-fast:
    returns [Error "missing target_type"] / [Error "invalid
    target_type"] when the [target_type] field is missing or
    unrecognised; field-by-field reads via Yojson.Util may
    raise [Type_error] which is caught and surfaced as
    [Error]. *)

(** {1 Freshness} *)

val generated_at_unix : record -> float
val fresh_until_unix : record -> float
(** Field accessors — present because the [is_fresh] / freshness
    comparison logic is duplicated in dashboard rendering. *)

val is_fresh : ?now:float -> record -> bool
(** [is_fresh ?now record] returns [true] iff
    [record.fresh_until_unix > now] (default [now]:
    {!Unix.gettimeofday}).  Pinned [>] (strict) rather than
    [>=]: a judgment that expires exactly now is stale, not
    fresh. *)

(** {1 Persistence} *)

val judgments_path : Workspace.config -> string
(** [judgments_path config] returns
    [<masc_dir>/operator/judgments.jsonl].  Exposed for tests
    that assert path existence after a [record] call. *)

val load_all : Workspace.config -> record list
(** Reads every JSONL entry from the judgments file, parses,
    and returns the records.  Parse failures are logged at
    [Log.Governance.warn] and skipped — operator alerts on
    "operator judgment parse:" prefix.  Returns the empty list
    when the file does not exist. *)

(** {1 Lookup}

    Records are keyed by [(surface, target_type, target_id)]
    triple.  When [target_id] is [None] or empty/whitespace, the
    composite key uses the literal [["__workspace__"]] marker —
    pinned because it must remain stable across runs. *)

val latest_active :
  Workspace.config ->
  surface:string ->
  target_type:target_type ->
  target_id:string option ->
  record option
(** Returns the most-recently-generated record for the
    [(surface, target_type, target_id)] key, comparing by
    [generated_at_unix].  None when the key has no records. *)

(** {1 Write} *)

val record :
  Workspace.config ->
  surface:string ->
  target_type:target_type ->
  target_id:string option ->
  summary:string ->
  confidence:float ->
  ?model_name:string ->
  ?runtime_name:string ->
  ?recommended_action:Yojson.Safe.t ->
  ?evidence_refs:string list ->
  ?fallback_used:bool ->
  ?disagreement_with_truth:bool ->
  generated_at:string ->
  ?generated_at_unix:float ->
  fresh_until:string ->
  ?fresh_until_unix:float ->
  keeper_name:string ->
  unit ->
  record
(** [record config ~surface ~target_type ~target_id ~summary
    ~confidence ... ()] persists a new judgment record.

    {2 Side effects}

    Creates the operator directory if absent, then appends one
    JSONL line to [judgments_path config].

    {2 Auto-fields}

    - [judgment_id]: generated via [generate_id ()] (private)
      from a 20-char random hex.
    - [supersedes]: auto-populated with the previous
      {!latest_active} judgment_id for the same key (or empty
      list if first).
    - [generated_at_unix]: [now] when omitted.
    - [fresh_until_unix]: parsed from [fresh_until] ISO string
      when omitted.
    - [confidence]: clamped to [\[0.0, 1.0\]].
    - [summary]: trimmed.
    - [evidence_refs]: trimmed + empty entries dropped.

    {2 status}

    Always [["active"]] on write.  A future "let's add a
    superseded status" change must touch this contract. *)
