(** Procedural Memory — Patterns extracted from repeated agent behavior.

    Crystallization uses adaptive thresholding:
    - Standard: 3+ occurrences with 70%+ positive outcomes
    - Rare-but-perfect: 2+ occurrences with 100% success rate

    Thresholds are configurable via [MASC_PROC_MIN_EVIDENCE] and
    [MASC_PROC_MIN_CONFIDENCE] environment variables.

    Crystallized procedures are injected into successor agents via
    capsule hydration.

    Storage: [.masc/procedures/{agent}/procedures.jsonl]

    @since 2.90.0 *)

(** {1 Types} *)

(** A learned procedure — "When X, do Y". *)
type procedure = {
  id : string;
  agent_name : string;
  pattern : string;            (** "When X, do Y" description *)
  evidence : string list;      (** Decision IDs supporting this pattern *)
  success_count : int;
  failure_count : int;
  confidence : float;          (** [success / (success + failure)] *)
  created_at : float;
  last_applied : float;
}

(** {1 Paths} *)

(** [.masc/procedures/{agent_name}/procedures.jsonl] under [base_path].
    Defaults to [Env_config.base_path ()] for existing callers. *)
val procedures_path : ?base_path:string -> agent_name:string -> unit -> string

(** {1 File I/O} *)

(** A strict load error carries the file path, the 1-based line number
    of the offending JSONL row, and the parser message. *)
type load_error = {
  path : string;
  line_number : int;
  message : string;
}

type load_result = (procedure list, load_error list) result
(** Result of a strict load: the parsed procedures or the list of
    errors encountered, each with line-level provenance. *)

(** Load all persisted procedures for [agent_name]. Malformed JSONL
    lines are silently skipped (via [of_json]). Returns [[]] if the
    file does not exist. *)
val load_procedures : ?base_path:string -> agent_name:string -> unit -> procedure list

(** Load all persisted procedures for [agent_name] strictly. Every
    JSONL line must parse and match the procedure schema. Returns
    [Error errors] on the first row that fails, with path, line
    number, and message. Returns [Ok []] when the file is missing. *)
val load_procedures_strict : ?base_path:string -> agent_name:string -> unit -> load_result

(** Append [p] to the agent's procedures file. Creates the directory
    if it does not exist. *)
val save_procedure : ?base_path:string -> agent_name:string -> procedure -> unit

(** Rewrite the full procedures file atomically. Returns [Error msg]
    when the atomic write fails so callers can decide whether to
    surface or log. *)
val rewrite_procedures : ?base_path:string -> agent_name:string -> procedure list -> (unit, string) result

(** {1 Crystallisation} *)

(** Adaptive crystallisation check:
    - Standard: [List.length p.evidence >= min_evidence ()]
      AND [p.confidence >= min_confidence ()].
    - Rare-but-perfect: [p.confidence >= 1.0] AND [List.length p.evidence >= 2]. *)
val is_crystallized : procedure -> bool

(** Top-N crystallised procedures sorted by confidence (descending). *)
val top_procedures :
  ?base_path:string -> agent_name:string -> limit:int -> unit -> procedure list
