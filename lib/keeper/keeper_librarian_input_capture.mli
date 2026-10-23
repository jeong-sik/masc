(** Complete pure retained Librarian input data, not a prompt/provider projection.
    Every input/message/context field and ordered metadata entry is retained.
    Tool-result JSON presence, recursive blocks, raw and typed reasoning detail,
    signed text and provenance remain distinct. No I/O, prompt lookup, domain
    judgment or execution/commit authority is provided. *)
val to_json : Keeper_librarian.input -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_librarian.input, string) result
(** Strict complete wire decode. Structured objects reject unknown, repeated or
    missing fields; payload JSON remains original data. Lists retain order and
    multiplicity. JSON-valued options use []/[value] to preserve Some Null.
    Existing complete domain codecs own fact/Goal/Task/turn identity parsing.
    This data restoration does not confirm physical owner, source freshness,
    provenance truth, live configuration or permission to perform any effect. *)
