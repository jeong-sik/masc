(** Meta_cognition_digest — board digest management.

    Manages meta-cognition digest posts on the board, including
    signature-based deduplication and latest-digest lookup.
    Pulled out of [meta_cognition.ml] as part of the god-file
    split; {!Meta_cognition} re-exports the public surface via
    [include Meta_cognition_digest], so callers reach
    {!latest_digest_json} either as
    [Meta_cognition.latest_digest_json] (the dashboard's
    namespace-truth path) or directly via this module.

    Internal helpers ([digest_hearth] / [digest_source] string
    constants, the [post_digest_key] meta extractor, and the
    [latest_digest_post] intermediate that returns
    [(post * digest_key)] tuples) are hidden — callers consume
    only the typed reference accessor and the JSON projection.

    @since God file decomposition — extracted from
    meta_cognition.ml *)

val latest_digest_ref :
  ?summary:Meta_cognition_types.summary_input ->
  unit ->
  Meta_cognition_types.digest_ref option
(** Look up the most recent digest post on the
    ["meta-cognition"] hearth (Automation_post,
    [Recent]-sorted, top-20 window) whose meta JSON has
    [source = "meta_cognition_digest"]. Returns [None] when no
    matching post exists.

    When [summary] is supplied, [matches_summary] in the result
    record is set iff the post's [digest_key] equals
    {!Meta_cognition_interpret.summary_signature} of the
    summary; otherwise [matches_summary] is [false]. *)

val latest_digest_json :
  ?summary:Meta_cognition_types.summary_input ->
  unit ->
  Yojson.Safe.t
(** {!latest_digest_ref} projected to a JSON object with the
    fields [post_id] / [title] / [created_at] / [updated_at] /
    [hearth] / [digest_key] / [matches_summary] / [provenance].
    [provenance] is always [`String "board"] so dashboard
    consumers can attribute the digest to its source surface;
    [updated_at] / [hearth] render as [`Null] when absent on
    the underlying post. Returns [`Null] when no digest post
    matches. *)
