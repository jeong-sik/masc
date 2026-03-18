(** Lodge Topic Extraction — Heuristic, LLM, and Hybrid modes.

    Extracts topics from post content using keyword matching (heuristic),
    LLM-based semantic extraction, or a hybrid that falls back to heuristic
    when LLM fails or returns empty.

    Mode is controlled by MASC_TOPIC_MODE env var:
    - "heuristic" — keyword matching only (original behavior)
    - "llm" — LLM only (empty list on failure)
    - "hybrid" — LLM with heuristic fallback (default)

    @since 4.1.0 (ROADMAP Phase 2.2.2) *)

(** {1 Types} *)

(** Topic extraction mode *)
type topic_mode =
  | Heuristic  (** Keyword matching only *)
  | Llm        (** LLM-based extraction only *)
  | Hybrid     (** LLM with heuristic fallback *)

(** {1 Mode} *)

val get_topic_mode : unit -> topic_mode
(** Read MASC_TOPIC_MODE env var. Default: Hybrid. *)

(** {1 Extraction} *)

val extract_topics : string -> string list
(** Main entry point. Dispatches to heuristic, LLM, or hybrid based on mode. *)

val extract_topics_heuristic : string -> string list
(** Keyword-based extraction with compound phrases and frequency scoring.
    Compound phrases (e.g. "functional-programming") are checked first,
    then single keywords sorted by occurrence count. *)

val extract_topics_llm : string -> (string list, string) result
(** LLM-based extraction with caching. Returns Error on LLM failure. *)

(** {1 Merge} *)

val merge_topics : primary:string list -> secondary:string list -> string list
(** Merge two topic lists: [primary] first, then unique [secondary] entries.
    Deduplicates and caps at 8. Used by hybrid mode to combine LLM + heuristic. *)

(** {1 Heuristic Internals} *)

val count_occurrences : string -> string -> int
(** [count_occurrences text keyword] counts non-overlapping matches of
    [keyword] in [text]. Exposed for testing. *)

val match_compound : string -> string -> bool
(** [match_compound lower_text phrase] checks if a kebab-case [phrase]
    matches in [lower_text] (both "kebab-case" and "space separated" forms). *)

(** {1 Helpers} *)

val truncate_topics : string list -> string list
(** Truncate a list to at most [max_topics] (8) items. *)

val filter_topic_items : Yojson.Safe.t list -> string list
(** Filter a Yojson list to valid lowercase topic strings (non-empty, <=50 chars). *)
(** {1 Parsing} *)

val parse_topics_response : string -> string list
(** Parse LLM response text into topic list.
    Uses bracket-aware scanning to handle nested brackets like ["type[T]"].
    Handles clean JSON arrays, JSON embedded in prose, trailing text, and malformed input.
    Filters oversized topics (>50 chars) and truncates to 8 items. *)

val find_array_bounds : string -> (int * int) option
(** Find the start and end positions of the outermost JSON array in a string.
    Uses depth tracking to handle nested brackets correctly. *)

val topics_response_is_valid : Llm_types.completion_response -> bool
(** Validate an LLM completion response. Used as [~accept] predicate so
    the cascade retries with the next model on garbage/empty responses. *)

(** {1 Prompt} *)

val build_topic_prompt : string -> string
(** Build the extraction prompt for a given content string. *)
