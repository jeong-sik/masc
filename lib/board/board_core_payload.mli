
(** Board_core_payload — post payload normalisation for the board store.

    Pulled out of [board_core.ml] as part of the god-file split;
    {!Board_core} re-exports the public surface via
    [include Board_core_payload]. Callers therefore reach these
    functions either qualified ([Board_core.normalize_post_payload]) or via
    the {!Board_core_payload} module directly. *)

type meta_parse_error = Meta_not_assoc of Yojson.Safe.t
(** Typed parse failure for [normalize_meta_json] / [normalize_post_payload].

    [Meta_not_assoc payload] indicates the caller passed a
    [Some yojson] meta value whose top-level shape is not
    [`Assoc _] (e.g. a bare [`String _], [`Int _], or [`List _]).
    Such payloads are malformed for board persistence — the legacy
    behaviour silently absorbed them as an empty meta object
    ([fields = []]) at [board_core_payload.ml:73], discarding the
    original value without any caller-visible signal. *)

val normalize_meta_json :
  Yojson.Safe.t option -> (Yojson.Safe.t option, meta_parse_error) result
(** Validate and normalize the JSON meta object.

    [None] and an empty [`Assoc] normalize to [Ok None]. A non-empty
    [`Assoc] is preserved.

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
    - the body is trimmed;
    - title is the trimmed [?title] when non-empty, else
      {!derive_post_title} of the body;
    - [post_kind] is passed through unchanged.

    Returns [Error (Meta_not_assoc _)] when [?meta_json] is
    [Some payload] with [payload] not of shape [`Assoc _]. *)
