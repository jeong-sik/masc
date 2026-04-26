(** Keeper_personality_io — symmetric I/O for keeper personality fields
    (will / needs / desires / instructions).

    SSOT for read, write, and compare paths. Replaces the read-only
    normalization in [Keeper_meta_json_parse] (which was symmetric only
    after Layer 1 PR-A #10479) and the raw write in [Keeper_meta_json].

    This module is being built as a samchon-style harness. The five
    layers are introduced in stacked commits within the same PR; the
    first commit lands [parse]/[to_json] and pins the round-trip
    invariant via [test/test_keeper_personality_io_parse.ml]. Subsequent
    commits add [coerce], [validate], [merge_with_defaults], and
    [compare_normalized]. Caller migration (Keeper_meta_json,
    Keeper_meta_json_parse, Keeper_runtime, Keeper_prompt) follows once
    the harness is complete.

    Layer 1 fix and 14-keeper byte audit (2026-04-26) confirmed only
    [nick0cave] exceeds the prompt_render_max_bytes cap, so the harness
    deliberately keeps cap-exceeding values intact on disk and warns
    only at the create/update boundary. *)

(** Raw personality record as it appears on disk and in memory. The
    four fields are kept separate from the rest of [keeper_meta] so
    the I/O harness can reason about them without dragging the full
    record schema into every test. *)
type raw_personality = {
  will : string;
  needs : string;
  desires : string;
  instructions : string;
}

val empty : raw_personality
(** All four fields = "". Useful as a fallback when a keeper has no
    persisted JSON yet. *)

val parse : ?defaults:raw_personality -> Yojson.Safe.t -> raw_personality
(** [parse ?defaults json] reads the four personality strings from a
    keeper JSON object, falling back to [defaults] (or [empty]) when
    a field is missing or the wrong shape. **No normalization is
    applied** — that belongs to the [coerce] layer added in a later
    commit. The return value is the raw bytes as persisted. *)

val to_json : raw_personality -> (string * Yojson.Safe.t) list
(** [to_json p] returns the four [(key, `String value)] pairs in the
    canonical order used by [Keeper_meta_json.meta_to_json]. The pairs
    are returned as a list (rather than an [`Assoc]) so the caller can
    splice them into a larger record without an intermediate
    [Yojson.Safe.Util.combine] round-trip. *)
