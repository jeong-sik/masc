(** Effect_evidence -- Source-path evidence at the Mode_enforcer boundary.

    Captures [source_path] and [source_line] from the call site where a
    mode-enforcement effect payload is produced. OAS writes these rows to
    [evidence/effects.json]; [mode_violations.json] remains the older grouped
    summary surface.

    Both fields are optional for backward compatibility with existing
    proof artifacts that pre-date this evidence layer.

    @since SafeAuto source-path boundary *)

(** Source-path evidence from the Mode_enforcer call site. *)
type t =
  { source_path : string option (** Path of the file that triggered the effect. *)
  ; source_line : int option (** Line number within [source_path]. *)
  }

(** The empty evidence record: both fields are [None]. *)
val empty : t

(** [is_populated ev] returns [true] when [ev.source_path] is non-empty
    after trimming whitespace. *)
val is_populated : t -> bool

(** Parse evidence from a JSON object.  Returns [empty] when neither
    [source_path] nor [source_line] is present.  Unknown fields are
    ignored. *)
val of_json : Yojson.Safe.t -> t

(** Parse [evidence/effects.json], returning [Error] when the artifact is not
    a JSON array. Individual rows are lenient because source-path evidence is
    enrichment on top of OAS' effect schema. *)
val of_json_list : Yojson.Safe.t -> (t list, string) result

(** [any_source_path_present events] is true when at least one effects row
    carries a non-empty [source_path]. *)
val any_source_path_present : t list -> bool

(** [check_any_source_path_present events] fails when the effects artifact
    contains no [source_path]. Use this at proof-consumption boundaries that
    must not silently lose Mode_enforcer call-site evidence. *)
val check_any_source_path_present : t list -> (unit, string) result

(** Serialize evidence to a JSON assoc list (sorted keys).
    Omits fields that are [None]. *)
val to_json_fields : t -> (string * Yojson.Safe.t) list
