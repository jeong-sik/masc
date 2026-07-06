
(** Tool_help_registry — derived per-tool help entries.

    Generates {!help_entry} records from {!Masc_domain.tool_schema} via
    a layered pipeline:

    + Manual override table (curated entries for prominent tools).
    + Schema metadata extraction (description, constraints).
    + Schema-derived summaries and details.

    Internal: 11 text helpers ([normalize_spaces],
    [trim_terminal_punctuation], [first_sentence], [truncate],
    [help_prompt_hints], [default_when_to_use],
    [constraints_from_metadata], [manual_help_entry],
    [derived_short_description], [derived_details]),
    [canonicalize_schema] (singular — folded into
    {!canonicalize_schemas}), [index_json] (no external caller),
    [validate_short_description] (no external caller). *)

(** {1 Help entry record} *)

type help_entry = {
  name : string;
  short_description : string;
      (** First-sentence summary, terminal punctuation trimmed. *)
  when_to_use : string;
      (** When the operator should reach for this tool. *)
  key_constraints : string list;
      (** Pre/post conditions, quotas, etc. *)
  details_markdown : string;
      (** Long-form Markdown body, may include examples. *)
  doc_refs : string list;
      (** Related runbook / wiki / spec references. *)
  prompt_hints : string list;
      (** LLM-facing usage hints (kept separate from
          [details_markdown] so prompt builders can splice them
          without dragging the full body). *)
  examples : string list;
      (** RFC-0195 P0 — Anthropic MCP guidance: examples > longer
          descriptions for parameter accuracy. Empty list means
          "no curated example yet"; entries are short, copy-able
          invocation snippets. *)
  alternatives : string list;
      (** RFC-0195 P0 — typed list of sibling tool names the LLM
          may try when this one rejects or is unavailable. Empty
          list means "terminal — this is the only path". RFC-0194
          §2 instantiation: every LLM-blocking gate names an
          alternative via descriptor metadata, not per-error prose. *)
}

(** {1 Lookup} *)

val entry_of_schema : Masc_domain.tool_schema -> help_entry
(** [entry_of_schema schema] returns the help entry for [schema].
    Resolution priority:

    + Manual override table (\[manual_help_entry\]).
    + Schema-derived fields (description -> short, metadata ->
      constraints).
    + Schema-derived summary/details ([derived_short_description] +
      [derived_details]).

    Always returns a valid record — degraded entries surface
    with empty [details_markdown] / [prompt_hints]. *)

val find_entry :
  Masc_domain.tool_schema list -> string -> help_entry option
(** [find_entry schemas name] returns the {!help_entry} for the
    named tool by composing
    [List.find_opt] over [schemas] with {!entry_of_schema}.  Returns
    [None] when no schema with that name exists. *)

(** {1 Schema canonicalization} *)

val canonicalize_schemas :
  Masc_domain.tool_schema list -> Masc_domain.tool_schema list
(** [canonicalize_schemas schemas] applies the canonicalization
    pass to every schema (description normalisation, constraint
    de-duplication).  Used by {!Capability_registry} during
    catalog assembly so consumers see a canonical shape regardless
    of source ordering or whitespace drift. *)

(** {1 Rendering} *)

val entry_json : help_entry -> Yojson.Safe.t
(** [entry_json entry] returns the JSON shape consumed by the
    [masc_tool_help] tool response.  Includes a [meta] field
    populated from {!Tool_catalog.metadata_to_fields entry.name}
    — pinned at the contract seam so the dashboard tooltip view
    sees the same metadata layout across refactors. *)

val entry_markdown : help_entry -> string
(** [entry_markdown entry] renders [entry] as a Markdown document
    with header / short / when-to-use / constraints / details /
    doc-refs sections.  Used by the
    [masc://tool-help/<name>] resource handler. *)

val index_markdown : Masc_domain.tool_schema list -> string
(** [index_markdown schemas] renders a Markdown index of every
    [(name, short_description)] pair in [schemas].  Used by the
    [masc://tool-help] root resource. *)
