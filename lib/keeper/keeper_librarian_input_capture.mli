(** Complete pure retained Librarian input data, not a prompt/provider projection.
    Every input/message/context field and ordered metadata entry is retained.
    Tool-result JSON presence, recursive blocks, raw and typed reasoning detail,
    signed text and provenance remain distinct. No I/O, prompt lookup, domain
    judgment or execution/commit authority is provided. *)
val to_json : Keeper_librarian.input -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Keeper_librarian.input, string) result
(** Strict complete wire decode. Structured objects reject unknown, repeated or
    missing fields, including message origin; metadata never supplies a missing
    typed origin. Payload JSON remains original data. Lists retain order and
    multiplicity. JSON-valued options use []/[value] to preserve Some Null.
    Existing complete domain codecs own fact/Goal/Task/turn identity parsing.
    This data restoration does not confirm physical owner, source freshness,
    provenance truth, live configuration or permission to perform any effect. *)

val message_json : Agent_core.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> (Agent_core.Types.message, string) result
(** The same complete message codec for retained checkpoint and fragment data.
    This preserves fields omitted by provider/checkpoint projections and grants
    no source or execution authority. *)
