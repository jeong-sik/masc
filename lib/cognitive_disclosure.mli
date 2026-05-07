(** Cognitive disclosure backend - Master Report Dim01 P0 #1 (RFC-0035 PR-8).

    Backend OCaml mirror of the dashboard `CognitiveDisclosure*` types
    in `dashboard/src/components/common/cognitive-disclosure.ts`.

    Master Report section 1.2 defines the 3-tier cognitive model:

    - L1 Perceive   - direct signal (titles, metrics, headlines)
    - L2 Comprehend - grouped meaning (summaries, narratives)
    - L3 Project    - forward state (analysis, projection,
      recommendation)

    The host emits a stream of {!item} values; the dashboard renders
    them by level. This module owns the schema and the
    `summarize` invariant. UI rendering stays in the dashboard.

    Boundary discipline (same rule as RFC-0035 PR-7 cognitive_mode):

    - Backend owns: level taxonomy, item record, summarize function,
      JSON wire format.
    - Dashboard owns: rendering, label/caption strings, layout.
      Backend exposes label/caption helpers for telemetry/Prometheus
      label parity, but they are not the wire format SSOT.

    Pure OCaml - no Eio, no I/O, no global state.

    @stability Evolving
    @since 0.19.18 *)

(** Master Report section 1.2 3-tier disclosure level. Wire format:
    `"perceive"` | `"comprehend"` | `"project"`. *)
type level =
  | Perceive
  | Comprehend
  | Project

val level_to_string : level -> string
val level_of_string : string -> (level, string) result

(** [all] returns the canonical L1 -> L3 ordering. *)
val all : level list

(** [level_index L1] = 1, [L2] = 2, [L3] = 3. Matches the dashboard's
    `L${index + 1}` rendering. *)
val level_index : level -> int

(** Human-readable label per level (mirrors the dashboard's `label`
    in [LEVEL_META]). *)
val level_label : level -> string

(** Human-readable caption per level (mirrors the dashboard's
    `caption` in [LEVEL_META]). *)
val level_caption : level -> string

(** A single disclosure item - one entry rendered under exactly one
    level column. [title] / [summary] are mandatory; [detail],
    [metric] are optional. [default_open] hints to the renderer
    whether the entry should start expanded; defaults to [false]. *)
type item = {
  level : level;
  title : string;
  summary : string;
  detail : string option;
  metric : string option;
  default_open : bool;
}

(** Aggregate view returned by {!summarize}. Mirrors the dashboard's
    `CognitiveDisclosureSummary`. *)
type disclosure_summary = {
  total : int;
  perceive_count : int;
  comprehend_count : int;
  project_count : int;
  open_default_level : level option;
  complete : bool;
}

(** [summarize items] walks [items] in order, counts per level,
    records the first [default_open=true] item's level, and computes
    [complete = every level has >= 1 item]. Empty input yields
    [{ total = 0; ... ; complete = false }]. *)
val summarize : item list -> disclosure_summary

(** [items_at_level l items] returns all items whose [level = l],
    in input order. *)
val items_at_level : level -> item list -> item list

(** {1 JSON codec}

    Wire format matches `chronicle-types.ts` style: camelCase
    (`defaultOpen`), level values as lowercase strings. Optional
    fields are absent (not null) on emit, accepted as null OR
    absent on decode. *)

val item_to_yojson : item -> Yojson.Safe.t
val item_of_yojson : Yojson.Safe.t -> (item, string) result

val summary_to_yojson : disclosure_summary -> Yojson.Safe.t

(** {1 Invariant check}

    Lightweight structural validation. Returns [Ok ()] on a
    well-formed item; otherwise [Error msg]. *)
val is_well_formed : item -> (unit, string) result
