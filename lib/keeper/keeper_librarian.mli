(** Keeper_librarian — structured claim extraction for the Memory OS.

    This module is intentionally pure: it does not perform I/O or LLM calls.
    It produces a prompt from a slice of messages and parses the LLM's
    structured JSON response into a [Keeper_memory_os_types.episode].

    The caller (typically the compaction pipeline in [Keeper_compact_policy])
    is responsible for:
    - selecting which messages to compress,
    - invoking the LLM with the prompt,
    - persisting the returned [episode] via [Keeper_memory_os_io]. *)

(** Input bundle for a single librarian extraction. *)
type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  }

(** Render the librarian extraction prompt from a message slice.
    The prompt asks for strict JSON matching the episode schema. *)
val prompt_of_input : input -> string

(** Parse a raw LLM response into an [episode].
    Returns [None] if the response is not valid JSON or violates invariants
    (e.g., empty claims with zero confidence, missing required fields). *)
val episode_of_output : input -> string -> Keeper_memory_os_types.episode option

(** Convenience: scrub internal state markers from messages before passing
    them to the librarian, so extracted summaries do not echo private
    runtime markers. *)
val scrub_messages_for_librarian : Agent_sdk.Types.message list -> Agent_sdk.Types.message list
