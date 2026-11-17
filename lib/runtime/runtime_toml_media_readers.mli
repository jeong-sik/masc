(** Strict decoding of the runtime-owned media reader declaration list. *)

val parse_media_readers :
  Otoml.t ->
  (Runtime_schema.media_reader_decl list, Runtime_toml_base.parse_error list) result
(** An absent section or an empty array declares no readers. Both table arrays
    and arrays of inline tables are accepted; named/singleton tables are not.
    Every row requires exactly [id], [revision], [kind], [media_types],
    [adapter], [command] and [args]. Duplicate keys and reader IDs are refused.

    IDs, revisions and commands must be nonblank and are preserved verbatim.
    Kinds and adapters use exact wire labels. MIME declarations are exact,
    nonblank strings; no case folding, trimming, format whitelist or attachment
    MIME rewriting occurs. An empty support list declares no supported MIME.
    Overlapping support across distinct IDs is preserved and does not select a
    reader. Declaration order is neither priority nor fallback order.

    Commands and arguments cannot contain NUL. Arguments otherwise retain
    order, whitespace and empty strings. This parser never expands or checks a
    host path, probes a reader, selects one, or starts external work. *)
