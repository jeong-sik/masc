(** Keeper_personality_io — symmetric I/O for the keeper [instructions]
    persona field.

    SSOT for read, write, and compare paths. The field is kept
    separate from the rest of [keeper_meta] so the I/O harness can reason
    about it without dragging the full record schema into every test. *)

type raw_personality = { instructions : string }

val empty : raw_personality
(** [instructions = ""]. Useful as a fallback when a keeper has no
    persisted JSON yet. *)

val parse : ?defaults:raw_personality -> Yojson.Safe.t -> raw_personality
(** [parse ?defaults json] reads the [instructions] string from a keeper
    JSON object, falling back to [defaults] (or [empty]) when the field
    is missing or the wrong shape. **No normalization is applied** — that
    belongs to the [coerce] layer. The return value is the raw bytes as
    persisted. *)

val to_json : raw_personality -> (string * Yojson.Safe.t) list
(** [to_json p] returns the [(key, `String value)] pair in the canonical
    order used by [Keeper_meta_json.meta_to_json]. Returned as a list
    (rather than an [`Assoc]) so the caller can splice it into a larger
    record without an intermediate round-trip. *)

(** Personality after the coerce step. Wraps [raw_personality] so the
    type system distinguishes "trimmed and ready for compare" from
    "as persisted on disk". Use [to_raw] to project back to the disk
    representation. The constructor is private — only [coerce] can
    produce a value of this type. *)
type coerced_personality

val coerce : raw_personality -> coerced_personality
(** [coerce p] applies the canonical text normalisation used by the
    compare path: [String.trim]. No truncation, no NFC, no encoding
    rewrite — those belong to the prompt-render path
    ([to_prompt_form ~max_bytes]). Idempotent. *)

val to_raw : coerced_personality -> raw_personality
(** Project a coerced value back to a [raw_personality]. Loses the
    "this has been coerced" type tag but keeps the byte contents. *)

(** {1 Validate} *)

(** Identifier of the personality field that triggered a warning.
    Wrapping in a sum makes the cap-warning record portable without
    leaking string keys. *)
type field = Instructions

val field_to_string : field -> string
(** Snake_case name of the field — stable identifier for log lines and
    Otel_metric_store labels. *)

(** Soft warning emitted when a field exceeds the configured byte cap.
    The harness never truncates: callers decide whether to soft-warn
    (default for boundary code) or reject. *)
type cap_warning = {
  field : field;
  observed_bytes : int;
  cap_bytes : int;
  hint : string;
}

val check_byte_caps :
  ?max_bytes:int -> coerced_personality -> cap_warning list
(** [check_byte_caps ?max_bytes p] returns a warning when the field
    exceeds the cap. [max_bytes] defaults to
    [Keeper_config.prompt_render_max_bytes]. Always pure — no logging, no
    Otel_metric_store, no transformation. *)

(** {1 Compare} *)

(** Per-field drift report when two coerced personalities differ.
    [diff_offset] is the byte index of the first differing character
    in the trimmed values, useful for log strings like
    [instructions(cur=319,tgt=357,diff@319)]. *)
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
(** [compare_normalized current target] returns [`Equal] when the field
    matches byte-for-byte after coerce, or [`Drift diffs] otherwise.
    Because both inputs are already [coerced_personality], there is no
    way to compare a raw value against a trimmed one — the type system
    enforces the symmetry. *)

(** {1 Render for prompt} *)

val to_prompt_form :
  max_bytes:int -> raw_personality -> raw_personality
(** [to_prompt_form ~max_bytes p] returns a copy of [p] with the field
    trimmed and then truncated to [max_bytes] on a UTF-8 boundary. This
    is the only place in the harness where data is shortened — parse /
    coerce / compare all preserve raw bytes. *)
