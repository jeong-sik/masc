(** Pure rendering and formatting helpers shared by {!Chrome}, {!Screen_pulse},
    and {!Overlays}. Zero global mutable state, zero I/O, zero SGR dim, and
    strict width-1 geometric glyphs. *)

open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

val layout_breakpoint_of_model : Model.breakpoint -> Layout.breakpoint

val target_keeper_of_model : Model.t -> string
(** Internal draft/store lookup key for the target keeper (may be
    {!Drafts.default_keeper_key} when no keeper is selected). *)

val display_target_keeper_of_model : Model.t -> string
(** Human-facing target keeper label for UI chrome (localized ["미선택"] /
    ["none"] when no keeper is active — never leaks ["_default"]). *)

val composer_state_of_model : Model.t -> Composer.state

val freshness_pill :
  model:Model.t ->
  compact:bool ->
  Glyph.t * string * Theme.status_token
(** Project authoritative per-view SSOT telemetry provenance into a single
    width-1 geometric glyph, localized label, and semantic status token. *)

val footer_ssot_hint : model:Model.t -> string
(** Exact right-aligned footer hint reflecting whether the active surface is
    backed by live SSE push, observer-synced HTTP snapshot, or manual-refresh
    HTTP snapshot. *)

val attention_kind_tag : Health.attention_kind -> Say.t
val attention_kind_keeper : Health.attention_kind -> string option

val keeper_health_glyph_and_tone :
  Wire_fleet.keeper_health -> Glyph.t * Theme.status_token

val format_hhmm_with_offset : tz_offset_sec:int -> float -> string option
(** Pure wall-clock [HH:MM] formatter from Unix epoch seconds shifted by
    [tz_offset_sec] ([None] when [<= 0.0] or non-finite). *)

val format_hhmm_utc : float -> string option
(** Pure UTC [HH:MM] formatter from Unix epoch seconds ([None] when [<= 0.0] or
    non-finite). *)

val format_relative_age : now_unix:float -> at_unix:float -> string option
(** Compact elapsed age (e.g. ["14m"], ["2h"]) when both timestamps are valid
    and [now_unix >= at_unix]. *)

val format_milli_candles : string -> string
(** Format a decimal milli-candle ledger string (e.g. ["12450"]) as ["12.45 C"]
    without raising on malformed input. *)

val contains_ci : needle:string -> string -> bool
(** Case-insensitive ASCII substring search (zero regex). *)

val fuzzy_score : query:string -> string -> int option
(** Deterministic case-insensitive fuzzy match score (higher is better,
    [None] when no match). *)

val draw_hline :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  w:int ->
  style:Style.t ->
  unit

val draw_pill :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  fg:Color.t ->
  bg:Color.t ->
  ?bold:bool ->
  string ->
  int
(** Draw a space-padded pill and return total terminal columns advanced. *)

val dim_backdrop :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  unit
(** Visually recede underlying canvas cells behind a floating modal using
    explicit WCAG-compliant colors (never SGR dim) while keeping width-2
    grapheme partner invariants intact. *)

val extract_embedded_json : string -> (string option * Yojson.Safe.t) option
(** Extract a JSON object or array from either a raw JSON payload or a prefixed
    error payload (e.g. ["HTTP 500: {\"error\":...}"]). Returns
    [Some (prefix_opt, json)] on valid JSON structure, or [None] without
    catching unrelated exceptions. *)

val redact_plain_text_secrets : string -> string
(** Redact secret key/value pairs (including truncated JSON fragments) and
    credential token patterns on plain-text diagnostic fallbacks. *)

val string_of_transport_error : lang:Say.lang -> Health.transport_error -> string
