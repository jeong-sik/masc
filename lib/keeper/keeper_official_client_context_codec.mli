(** Lossless framing for canonical Keeper messages carried over official-client
    text-only history surfaces. *)

val schema : string

(** What the encoded text is for. [Canonical_source] is the text a stored
    session, a held-context hash or a byte measure is compared against; it
    holds nothing that changes with the clock. [Session_start] is the text a
    new vendor session is seeded with at [started_at] (Unix seconds); it adds
    each recorded tool result's age at that moment. *)
type rendering =
  | Canonical_source
  | Session_start of { started_at : float }

val message_to_json : rendering -> Agent_core.Types.message -> Yojson.Safe.t
(** Preserve role, every typed content block, message identity, metadata,
    structured ToolResult content, and typed failure provenance. Two metadata
    entries stay out: the {!Agent_core.Types.Input_speaker} entry, host
    attribution for the Librarian, and the
    {!Agent_core.Types.Tool_results_appended_at} entry. A Tool message carries
    that time as [result_time] instead: [{"state": "recorded", "appended_at":
    <RFC 3339>}] (plus [age_at_session_start] and [age_seconds] in a
    [Session_start] rendering), [{"state": "unrecorded"}] with no stamp, and
    [{"state": "invalid"}] or [{"state": "duplicate"}] for a broken one. *)

val to_json : rendering -> Agent_core.Types.message -> Yojson.Safe.t
(** Wrap one exact message in the current context schema. *)

val encode : rendering -> Agent_core.Types.message -> string
(** Encode every role through the same versioned envelope. Raw user bytes never
    occupy the framing layer. *)

val canonical_source_sha256 :
  system_prompt:string ->
  messages:Agent_core.Types.message list ->
  rest:(string * Yojson.Safe.t) list ->
  string
(** Hex SHA-256 of the canonical source a vendor session is seeded from: the
    JSON object [{"system_prompt": …, "messages": […], …rest}] written compact,
    each message through [to_json Canonical_source], [rest] after the two fields in the order
    given. A session store compares a stored session against this value, so
    the text it hashes is part of the stored format.

    Called from a fiber of a process with a domain pool, the work runs as one
    job of that pool and the fiber waits for it; elsewhere it runs where it is
    called. *)
