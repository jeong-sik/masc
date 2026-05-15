
(** Board_core_payload — [STATE] block extraction and post payload
    normalisation for the board store.

    Pulled out of [board_core.ml] as part of the god-file split;
    {!Board_core} re-exports the public surface via
    [include Board_core_payload]. Callers therefore reach these
    functions either qualified ([Board_core.normalize_post_payload])
    or via the {!Board_core_payload} module directly (the test
    suite does the latter for [derive_post_title]).

    Internal helpers (the precompiled [start_re] / [end_re] regexes
    and the raw [state_start_marker] / [state_end_marker] strings)
    are hidden — callers consume only the parser, the meta-merge
    helper, the title deriver, and the payload normaliser. *)

val extract_state_block : string -> string option * string
(** Extract a single [\[STATE\]…\[/STATE\]] block from [text].

    Returns [(state_block_with_markers, body_without_block)] —
    the trimmed state block (markers retained) when present and
    the trimmed remainder of [text] with the block stripped out.
    When no opening marker is found, returns [(None, String.trim
    text)]. When the opening marker has no matching close, the
    block extends to end-of-text. *)

val meta_state_block : Yojson.Safe.t option -> string option
(** Read the [state_block] field from a JSON meta object.

    Returns [Some s] when [meta_json] is a JSON object containing
    a non-empty string [state_block]. Returns [None] for
    [None] / non-object / non-string / empty-after-trim values. *)

type meta_parse_error = Meta_not_assoc of Yojson.Safe.t
(** Typed parse failure for [merge_meta_json] / [normalize_post_payload].

    [Meta_not_assoc payload] indicates the caller passed a
    [Some yojson] meta value whose top-level shape is not
    [`Assoc _] (e.g. a bare [`String _], [`Int _], or [`List _]).
    Such payloads are malformed for board persistence — the legacy
    behaviour silently absorbed them as an empty meta object
    ([fields = []]) at [board_core_payload.ml:73], discarding the
    original value without any caller-visible signal. *)

val merge_meta_json :
  ?state_block:string ->
  Yojson.Safe.t option ->
  (Yojson.Safe.t option, meta_parse_error) result
(** Merge a [state_block] string into the JSON meta object.

    When [meta_json] is [None] or [Some (`Assoc _)], returns
    [Ok merged] where [merged] is the [`Assoc] payload with
    [state_block] added iff it is [Some non_empty] and the object
    does not already contain a [state_block] entry (existing
    entries are preserved). [None] meta with no state_block
    yields [Ok None]; otherwise [Ok (Some (`Assoc fields))].

    Returns [Error (Meta_not_assoc payload)] when [meta_json] is
    [Some payload] with [payload] not of shape [`Assoc _]. Callers
    must decide explicitly whether to reject, log, or repair. *)

val derive_post_title : string -> string
(** Derive a post title from [body].

    Picks the first non-empty trimmed line, defaulting to
    ["Untitled post"] for empty input, then truncates with a
    UTF-8-safe byte boundary at 80 bytes (suffix ["..."] when
    truncation occurs). Regression-tested for issue #7690 — the
    pre-fix [String.sub] could split multi-byte Korean / emoji
    characters and produced invalid UTF-8 lines in
    [board_posts.jsonl]. *)

val normalize_post_payload :
  content:string ->
  ?title:string ->
  ?body:string ->
  post_kind:Board_types.post_kind ->
  ?meta_json:Yojson.Safe.t ->
  unit ->
  ( string * string * Board_types.post_kind * Yojson.Safe.t option,
    meta_parse_error )
  result
(** Normalise a post submission into the canonical
    [(title, body, kind, meta)] tuple persisted to
    [board_posts.jsonl].

    Pipeline:
    - body defaults to [content] when omitted;
    - any embedded [\[STATE\]…\[/STATE\]] block is extracted via
      {!extract_state_block} and lifted into [meta.state_block]
      via {!merge_meta_json};
    - the body is trimmed;
    - title is the trimmed [?title] when non-empty, else
      {!derive_post_title} of the stripped body;
    - [post_kind] is passed through unchanged.

    Returns [Error (Meta_not_assoc _)] when [?meta_json] is
    [Some payload] with [payload] not of shape [`Assoc _]. *)
