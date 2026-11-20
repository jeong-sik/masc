(** Deterministic, length-bounded wire mapping for canonical tool-call IDs.

    Canonical history preserves the originating provider's tool-call identity
    verbatim. Downstream wires impose stricter limits:
    - OpenAI Chat Completions and Responses cap tool-call IDs at 40 bytes.
    - Anthropic Messages requires tool-use IDs of 1..64 bytes matching
      [a-zA-Z0-9_-]+.

    When an ID already satisfies the target wire's contract, it is emitted
    unchanged. Otherwise it is mapped deterministically using a sanitized
    prefix and a 64-bit SHA-256 digest suffix so distinct canonical IDs remain
    distinct and matching [ToolUse]/[ToolResult] pairs correlate across turns,
    checkpoints, and provider failovers. *)

val openai_max_length : int
val anthropic_max_length : int

(** Map a canonical tool-call identity to an OpenAI-safe wire identity
    (1..40 bytes). Identity on already-compliant IDs. *)
val wire_id_for_openai : string -> string

(** Map a canonical tool-call identity to an Anthropic-safe wire identity
    (1..64 bytes matching [^[a-zA-Z0-9_-]+$]). Identity on already-compliant
    IDs. *)
val wire_id_for_anthropic : string -> string

(** Dispatch wire-ID normalization for a declared {!Provider_kind.t}:
    - [OpenAI_compat] / [Glm]: {!wire_id_for_openai}
    - [Anthropic] / [Kimi]: {!wire_id_for_anthropic}
    - [Gemini] / [Ollama]: identity *)
val wire_id_for_provider_kind : Provider_kind.t -> string -> string

(** Pure bidirectional correlation table built from known canonical tool-call
    identities, enabling round-trip lookup between canonical and wire IDs. *)
type correlation

val build_correlation : (string -> string) -> string list -> correlation
val to_wire : correlation -> string -> string
val to_canonical : correlation -> string -> string
