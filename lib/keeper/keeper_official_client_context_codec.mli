(** Lossless framing for canonical Keeper messages carried over official-client
    text-only history surfaces. *)

val schema : string

val message_to_json : Agent_core.Types.message -> Yojson.Safe.t
(** Preserve role, every typed content block, message identity, metadata,
    structured ToolResult content, and typed failure provenance. The one
    exception is the {!Agent_core.Types.Input_speaker} entry: it is host
    attribution for the Librarian, never text an official client reads. *)

val to_json : Agent_core.Types.message -> Yojson.Safe.t
(** Wrap one exact message in the current context schema. *)

val encode : Agent_core.Types.message -> string
(** Encode every role through the same versioned envelope. Raw user bytes never
    occupy the framing layer. *)

val canonical_source_sha256 :
  system_prompt:string ->
  messages:Agent_core.Types.message list ->
  rest:(string * Yojson.Safe.t) list ->
  string
(** Hex SHA-256 of the canonical source a vendor session is seeded from: the
    JSON object [{"system_prompt": …, "messages": […], …rest}] written compact,
    each message through {!to_json}, [rest] after the two fields in the order
    given. A session store compares a stored session against this value, so
    the text it hashes is part of the stored format.

    Called from a fiber of a process with a domain pool, the work runs as one
    job of that pool and the fiber waits for it; elsewhere it runs where it is
    called. *)
