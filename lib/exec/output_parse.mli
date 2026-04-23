(** P10: Structured Output Extraction

    Pure-function parsers that turn raw command output into
    machine-readable JSON fields.  Every parser is total and returns
    [Some json] on a confident match or [None] to decline (fail-open).

    Inspired by OpenAI Codex harness blog posts ("harness-engineering"):
    agents waste tokens on fragile regex parsing of raw text.  This
    layer turns common outputs into typed JSON that the agent can
    consume directly. *)

val try_parse :
  cmd:string -> status:Unix.process_status -> output:string -> Yojson.Safe.t option
(** Top-level dispatcher.  Examines [cmd] to select a parser, then
    feeds [output] through it.  Returns [None] when no parser matches
    or when the output does not conform to the expected format. *)
