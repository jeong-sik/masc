(** Autoresearch_knowledge — research finding persistence
    (JSONL primary + GraphQL best-effort).

    Records structured research findings from autoresearch
    loops.  Local JSONL under
    [<masc_dir>/autoresearch/findings/findings.jsonl] is the
    primary store; GraphQL/Neo4j sync is best-effort and never
    blocks on failure.

    @since 2.122.0 *)

(** {1 Types} *)

type confidence = High | Medium | Low

type finding = {
  id : string;
  loop_id : string;
  keeper_name : string;
  goal : string;
  hypothesis : string;
  evidence : string;
  conclusion : string;
  confidence : confidence;
  tags : string list;
  related_findings : string list;
  cycle_range : (int * int) option;
        (** [(first_cycle, last_cycle)] when the finding spans
            a contiguous range of autoresearch loop cycles. *)
  timestamp : float;
}
(** Concrete record because tests
    ({!Test_autoresearch_knowledge}) construct findings field-
    by-field for fixture data. *)

(** {1 Confidence codec} *)

val confidence_to_string : confidence -> string
(** [High -> "high"] / [Medium -> "medium"] / [Low -> "low"].
    Pinned wire strings — operator dashboards key off these. *)

val confidence_of_string_opt : string -> confidence option
(** Partial parser.  Returns [None] for unrecognised input —
    callers that originate from user input (tool args, on-disk
    JSON) can distinguish "explicit medium" from "garbage or
    stale label" instead of silently coercing both to
    [Medium]. *)

val confidence_of_string : string -> confidence
(** Total parser kept for backward compatibility.  Falls back
    to [Medium] on unrecognised input AND writes a one-line
    [stderr] warning
    [["[autoresearch] WARN: unrecognised confidence "X", defaulting to medium"]]
    so operator typos (e.g. [confidence=hihg]) or data drift in
    stored findings surface instead of silently collapsing.
    Pinning at the contract seam — the warning prefix is
    operator-grep-visible. *)

(** {1 JSON codec} *)

val finding_to_yojson : finding -> Yojson.Safe.t
(** Renders the 12-field JSON object.  [cycle_range = None] →
    [`Null]; otherwise [`List [`Int a; `Int b]].  [timestamp]
    always emits as [`Float] (even for whole-second values) for
    parser symmetry with {!finding_of_yojson}. *)

val finding_of_yojson :
  Yojson.Safe.t -> (finding, string) result
(** Parses a finding JSON object back to a record.

    {2 Optional-field defaults}

    | Field | Default |
    |---|---|
    | [loop_id] | [""] |
    | [keeper_name] | ["unknown"] |
    | [confidence] | parsed via {!confidence_of_string} from "medium" default |
    | [tags] / [related_findings] | empty list (also when non-list) |
    | [cycle_range] | [None] (when not [`List [`Int _; `Int _]]) |
    | [timestamp] | [Unix.gettimeofday ()] when missing/invalid |

    Required fields ([id], [goal], [hypothesis], [evidence],
    [conclusion]) are read with {!Yojson.Util.to_string} which
    raises [Type_error] on shape mismatch — caught and
    surfaced as [Error <Printexc>]. *)

(** {1 Storage} *)

val findings_dir : base_path:string -> string
val findings_file : base_path:string -> string
(** Path computation: [<masc_dir>/autoresearch/findings/] and
    [<dir>/findings.jsonl].  Pinned relative paths — operator
    runbooks reference the exact location. *)

val ensure_findings_dir : base_path:string -> unit
(** Creates [findings_dir] if absent (mkdir-p semantics). *)

val append_finding : base_path:string -> finding -> unit
(** [append_finding ~base_path f] appends one JSONL line to
    [findings_file].  Auto-creates the directory.  Synchronous
    write — caller is responsible for batching if hot-path
    performance matters. *)

val load_all_findings :
  base_path:string -> unit -> finding list
(** [load_all_findings ~base_path ()] reads every JSONL line
    from the findings file and returns the parsed records.

    Returns the empty list when the file does not exist.
    Parse failures log at {!Log.Keeper.warn}
    [["Skipping malformed finding: <msg>"]] and skip the entry
    — operator alerts on this prefix. *)

val search_findings :
  base_path:string ->
  query:string ->
  ?limit:int ->
  unit ->
  finding list
(** [search_findings ~base_path ~query ?limit ()] returns the
    top [limit] (default [10]) findings whose concatenated
    haystack ([goal] + [hypothesis] + [evidence] + [conclusion]
    + space-joined [tags]) contains [query] case-insensitively.

    Findings are returned **most recent first**
    ([List.rev] over the load order which is oldest-first).
    Empty query matches everything — operator-visible
    "list-all" feature.

    Pure read — no side effects beyond reading the JSONL file. *)

(** {1 GraphQL sync} *)

val sync_to_graphql : finding -> (bool, string) result
(** [sync_to_graphql f] runs the [createFinding] GraphQL
    mutation against the configured GraphQL endpoint.

    Best-effort — failure logs at {!Log.Keeper.warn}
    [["Finding GraphQL sync failed (non-fatal): <msg>"]] and
    returns [Error msg].  Local JSONL is authoritative; the
    GraphQL sync is a search-index hint.  10-second timeout
    (operator-tunable only by code change).

    Sub-field convention pinned at the contract seam:
    [loopId] / [keeperName] empty strings render as [`Null] in
    the variable bindings (not as `String ""`), preserving the
    cross-module Null-vs-empty pattern. *)

(** {1 Public API} *)

val generate_finding_id : unit -> string
(** Random id prefixed with [["fn-"]] (6 random bytes).  Pinned
    prefix — operator runbooks grep on the [fn-] prefix to
    distinguish finding ids from other random ids in logs. *)

val record_finding :
  base_path:string -> finding:finding -> Yojson.Safe.t
(** [record_finding ~base_path ~finding] performs the canonical
    "record one finding" operation:

    1. Append to local JSONL ({!append_finding}).
    2. Best-effort GraphQL sync ({!sync_to_graphql}).
    3. Return [{"ok": true, "id": "<id>", "graphql_synced":
       <bool>}].

    The [graphql_synced] field reports the sync outcome — a
    [false] value means the finding is in the local store but
    not (yet) indexed in GraphQL.  Local JSONL remains
    authoritative. *)
