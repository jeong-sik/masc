(** btop-grade adaptive Chart Grammar painting directly onto
    {!Masc_tui_term.Cell_grid.t}.

    Design invariants:
    - Closed algebraic sum types for {!Spec.kind}, {!Render_mode.layout_mode},
      {!Render_mode.glyph_tier}, {!Gradient.t}, {!Scale.t}, and {!Series.sample}.
    - Deterministic mode resolution solely from [(avail_w, avail_h, caps, spec)].
    - Explicit missing-value semantics: [Unread] and [Absent] never collapse to
      [0] (they emit 0 Braille dots and show a calm Tier-4 italic notice when
      all samples are missing); [Zero] paints a 1-dot baseline; any positive
      [Value] paints strictly above baseline.
    - Braille plots paint directly via {!Masc_tui_term.Cell_grid.put_braille}
      with zero per-cell string allocations and precomputed 64-entry Oklab
      gradient LUTs from {!Masc_tui_core.Theme.t}. *)

module Format_val = Masc_tui_core.Format_val
module Observed = Masc_tui_core.Observed
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Cell_grid = Masc_tui_term.Cell_grid
module Presenter = Masc_tui_term.Presenter

module Time_window : sig
  type t =
    | Last_5m
    | Last_1h
    | Last_24h
    | Last_7d
    | Last_14d

  val label : t -> string
  val ticks : t -> string * string * string
  (** [(start_label, mid_label, end_label)] for the X-axis horizon. *)
end

module Gradient : sig
  type t =
    | Thermal
    | Cool_flow
    | Warm_flow
    | Efficiency
    | Ai_flow
    | Semantic_fixed of Theme.status_token

  val violet : t
  (** Alias for {!Ai_flow} (Violet Oklab gradient for Candle decay & AI metrics). *)

  val sample_rgb : Theme.t -> t -> float -> Theme.rgb
end

module Scale : sig
  type t =
    | Fixed_bounds of { floor : float; ceiling : float }
    | Auto_ceil of { floor : float; nice_step : bool }
    | Synced_pair

  val nice_ceiling : float -> float
  (** Round a positive ceiling up to a clean 1-2-5 step. *)
end

module Series : sig
  type sample =
    | Unread
    | Absent
    | Zero
    | Value of float

  type t = {
    label : Say.t;
    unit : Format_val.unit_kind;
    gradient : Gradient.t;
    samples : sample array;       (** Oldest to newest. *)
    current : float Observed.t;
    peak : float Observed.t;
    avg : float Observed.t;
    delta_pct : float option;
  }

  val sample_dot_level :
    dots:int -> floor:float -> ceiling:float -> sample -> int
  (** Map one sample onto [[0..dots]]: [Unread]/[Absent] -> [0] (blank),
      [Zero] -> [1] (baseline), positive finite [Value] -> [[2..dots]]. *)

  val resample_peak_preserving : target_len:int -> sample array -> sample array
  (** Bucket-resample [samples] to [target_len] subcolumns preserving bucket
      peaks and keeping [Unread]/[Absent] strictly distinct from [Zero]. *)
end

module Spec : sig
  type kind =
    | Time_series of {
        series : Series.t;
        scale : Scale.t;
        window : Time_window.t;
      }
    | Dual_inverted of {
        upper : Series.t;
        lower : Series.t;
        scale : Scale.t;
        window : Time_window.t;
      }
    | Ratio_gauge of {
        used : float Observed.t;
        limit : float Observed.t;
        unit : Format_val.unit_kind;
        gradient : Gradient.t;
        reset_hint : Say.t option;
      }
    | Stacked_bar of {
        segments : (Say.t * float * Theme.status_token) list;
        total_label : Say.t;
        unit : Format_val.unit_kind;
      }

  type t = {
    title : Say.t;
    kind : kind;
    hotkey_hint : string option;
  }
end

module Render_mode : sig
  type glyph_tier =
    | Braille_2x4
    | Block_vertical
    | Ascii_tty

  type gauge_glyphs =
    | Eighth_block
    | Half_block
    | Ascii_gauge

  type spark_glyphs =
    | Spark_eighth_block
    | Spark_ascii

  type layout_mode =
    | Full_area_chart of {
        glyphs : glyph_tier;
        plot_cols : int;
        plot_rows : int;
        show_y_axis : bool;
        show_x_ticks : bool;
        show_inline_legend : bool;
      }
    | Dual_mirror_chart of {
        glyphs : glyph_tier;
        plot_cols : int;
        half_rows : int;
        show_y_axis : bool;
        show_inline_legend : bool;
      }
    | Half_block_gauge of {
        glyphs : gauge_glyphs;
        bar_cols : int;
        multiline_detail : bool;
      }
    | Inline_sparkline of {
        glyphs : spark_glyphs;
        spark_cols : int;
      }
    | Numeric_delta_pill

  val equal_glyph_tier : glyph_tier -> glyph_tier -> bool
  val equal_layout_mode : layout_mode -> layout_mode -> bool

  val select_glyph_tier : caps:Presenter.capabilities -> glyph_tier

  val resolve :
    avail_w:int ->
    avail_h:int ->
    caps:Presenter.capabilities ->
    Spec.t ->
    layout_mode
end

val draw_sparkline_run :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  width:int ->
  theme:Theme.t ->
  bg:Masc_tui_term.Color.t ->
  unicode:bool ->
  gradient:Gradient.t ->
  Series.sample array ->
  int
(** Paint a 1-row inline sparkline directly onto [Cell_grid.t] (reused by
    {!Table} and compact charts). Returns columns drawn. *)

val draw_ratio_bar_run :
  ?clip:Rect.t ->
  Cell_grid.t ->
  x:int ->
  y:int ->
  width:int ->
  theme:Theme.t ->
  bg:Masc_tui_term.Color.t ->
  unicode:bool ->
  gradient:Gradient.t ->
  ratio:float ->
  int
(** Paint an eighth-block fractional ratio bar directly onto [Cell_grid.t] with
    the non-zero never-floor invariant and subtle [border_inactive] track.
    Returns columns drawn. *)

val draw :
  Cell_grid.t ->
  rect:Rect.t ->
  theme:Theme.t ->
  caps:Presenter.capabilities ->
  lang:Say.lang ->
  ?show_title:bool ->
  Spec.t ->
  Render_mode.layout_mode
(** Resolve {!Render_mode.layout_mode} for [rect] and paint the chart directly
    into [Cell_grid.t], returning the resolved mode. Pass [~show_title:false]
    when embedded inside a {!Card} whose border already displays the chart title
    so row 0 shows a clean subtitle/window + Now/Peak/Avg KPI summary only. *)
