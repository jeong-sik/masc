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

(** Personality after the coerce step. Wraps [raw_personality] so the
    type system distinguishes "trimmed and ready for compare" from
    "as persisted on disk". Use [to_raw] to project back to the disk
    representation. The constructor is private — only [coerce] can
    produce a value of this type. *)
type coerced_personality

val coerce : raw_personality -> coerced_personality
(** [coerce p] applies the canonical text normalisation used by the
    compare path: [String.trim] on every field. No truncation, no NFC,
    no encoding rewrite — those belong to the validate layer (length
    cap, structured errors) and to the prompt-render path
    ([Keeper_prompt.render_for_prompt ~max_bytes]) added in later
    commits. Idempotent: [coerce (to_raw (coerce p)) = coerce p]. *)

val to_raw : coerced_personality -> raw_personality
(** Project a coerced value back to a [raw_personality]. Loses the
    "this has been coerced" type tag but keeps the byte contents. *)

(** {1 Validate} *)

(** Identifier of the personality field that triggered a warning.
    Wrapping in a sum makes the cap-warning record portable to Layer 4
    structured-feedback responses without leaking string keys. *)
type field = Will | Needs | Desires | Instructions

val field_to_string : field -> string
(** Snake_case name of the field — stable identifier for log lines and
    Prometheus labels. *)

(** Soft warning emitted when a field exceeds the configured byte cap.
    The harness never truncates: callers decide whether to soft-warn
    (default for boundary code) or reject (Layer 4 self-edit). *)
type cap_warning = {
  field : field;
  observed_bytes : int;
  cap_bytes : int;
  hint : string;
}

val check_byte_caps :
  ?max_bytes:int -> coerced_personality -> cap_warning list
(** [check_byte_caps ?max_bytes p] returns a warning per oversized
    field. [max_bytes] defaults to [Keeper_config.prompt_render_max_bytes].
    Always pure — no logging, no Prometheus, no transformation. The
    caller chooses what to do with the warnings (soft-warn at create/
    update boundaries; structured-feedback in Layer 4 retry). *)

(** {1 Compare} *)

(** Per-field drift report when two coerced personalities differ.
    [diff_offset] is the byte index of the first differing character
    in the trimmed values, useful for log strings like
    [will(cur=319,tgt=357,diff@319)] (the format Layer 1
    [Keeper_runtime.personality_field_diff_entry] emits). *)
type field_diff = {
  field : field;
  current_bytes : int;
  target_bytes : int;
  diff_offset : int;
}

val compare_normalized :
  coerced_personality ->
  coerced_personality ->
  [ `Equal | `Drift of field_diff list ]
(** [compare_normalized current target] returns [`Equal] when every
    field matches byte-for-byte after coerce, or [`Drift diffs] with
    one entry per differing field (in canonical order:
    will, needs, desires, instructions).

    Replacement for [Keeper_runtime.personality_text_equal] /
    [personality_diff_summary] / [personality_field_diff_entry]
    introduced in Layer 1. Because both inputs are already
    [coerced_personality], there is no way to compare a raw value
    against a trimmed one — the type system enforces the symmetry
    Layer 1 had to enforce at runtime. *)

(** {1 Render for prompt} *)

val to_prompt_form :
  max_bytes:int -> raw_personality -> raw_personality
(** [to_prompt_form ~max_bytes p] returns a copy of [p] with each
    field trimmed and then truncated to [max_bytes] using
    [Keeper_config.utf8_safe_prefix_bytes] (UTF-8 boundary safe).
    This is the only place in the harness where data is shortened —
    parse / coerce / compare all preserve raw bytes. Callers are
    responsible for fallback defaults when a field is empty after
    trimming.

    The output type is [raw_personality] (not [coerced_personality])
    because the truncation may break the "trim-only" invariant —
    after slicing on a UTF-8 boundary the trailing whitespace
    promise no longer holds in general. *)
