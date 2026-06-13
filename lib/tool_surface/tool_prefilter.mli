
(** Tool_prefilter — TF-IDF cosine similarity for tool relevance scoring.

    Stateless. Index built per-call from provided tools.

    {b Zero-result contract}: returns [[]] when:
    - query tokenizes to nothing (empty/non-alphanumeric)
    - no token overlap between query and any tool document (all cosine = 0.0)

    Caller is responsible for fallback (e.g. use original tool list).

    @since 2.170.0 — #4574 *)

val filter :
  tools:Masc_domain.tool_schema list ->
  query:string ->
  k:int ->
  Masc_domain.tool_schema list
(** Return top-[k] tools from [tools] most relevant to [query].
    Returns [[]] on zero overlap. *)

val synonym_keys : string list
(** All tool names registered in the synonym dictionary.
    Test helper: verify every key maps to a known [Tool_name.t]. *)

val filter_with_scores :
  tools:Masc_domain.tool_schema list ->
  query:string ->
  k:int ->
  (Masc_domain.tool_schema * float) list
(** Return top-[k] tools with their cosine similarity scores.
    Returns [[]] on zero overlap. Useful for logging/debugging. *)

val synonym_text : string -> string
(** Return space-separated synonym keywords for a tool [name].
    Returns [""] if no synonyms are defined.
    Useful for enriching BM25 index descriptions with user-facing vocabulary. *)
