(** Effect_evidence — Source-path evidence at the Mode_enforcer boundary.

    Captures [source_path] and [source_line] from the call site where a
    mode-enforcement effect payload is produced.  These fields are attached
    to each violation record before any continuation is discontinued, so the
    backtrace survives the handler boundary intact.

    Both fields are optional for backward compatibility with existing
    [mode_violations.json] artifacts that pre-date this evidence layer.

    @since SafeAuto source-path boundary *)

(** Source-path evidence from the Mode_enforcer call site. *)
type t = {
  source_path : string option;  (** Path of the file that triggered the effect. *)
  source_line : int option;     (** Line number within [source_path]. *)
}

(** The empty evidence record: both fields are [None]. *)
val empty : t

(** [is_populated ev] returns [true] when [ev.source_path] is [Some _]. *)
val is_populated : t -> bool

(** Parse evidence from a JSON object.  Returns [empty] when neither
    [source_path] nor [source_line] is present.  Unknown fields are
    ignored. *)
val of_json : Yojson.Safe.t -> t

(** Serialize evidence to a JSON assoc list (sorted keys).
    Omits fields that are [None]. *)
val to_json_fields : t -> (string * Yojson.Safe.t) list
