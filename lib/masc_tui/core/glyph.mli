(** Closed width-1 geometric glyph registry.

    Every constructor maps to an unambiguous 1-cell Unicode glyph across macOS
    Terminal, iTerm2, Ghostty, WezTerm, Kitty, Alacritty, and tmux. Zero emojis
    and zero ambiguous-width symbols ([U+26A0] is replaced by [U+25B3],
    [U+26A1] is replaced by [*]). *)

type t =
  (* Channel 1: Human Action Required *)
  | Action_required         (** ◆ U+25C6 *)
  (* Channel 2: Live Operational SSOT State *)
  | Live_healthy            (** ● U+25CF *)
  | Live_working            (** ◐ U+25D0 *)
  | Live_working_frame of int (** Cycles ◐ ◓ ◑ ◒ modulo 4 *)
  | Live_idle               (** ○ U+25CB *)
  | Live_paused             (** ‖ U+2016 *)
  | Live_failing            (** ✕ U+2715 *)
  (* Channel 3: Historical Trail & Transport Freshness *)
  | Historical_incident     (** ▴ U+25B4 *)
  | Recovered               (** ◂ U+25C2 *)
  | Transport_reconnecting  (** ◌ U+25CC *)
  | Transport_stale         (** △ U+25B3 *)
  (* Chrome, Navigation, Deltas & Missing Values *)
  | Focus_caret             (** ▸ U+25B8 *)
  | Expand_open             (** ▾ U+25BE *)
  | Expand_closed           (** ▸ U+25B8 *)
  | Delta_up                (** ▲ U+25B2 *)
  | Delta_down              (** ▼ U+25BC *)
  | Delta_flat              (** ─ U+2500 *)
  | Missing_unreported      (** ? U+003F *)
  | Missing_absent          (** — U+2014 *)
  | Separator_dot           (** · U+00B7 *)
  | Prompt_caret            (** › U+203A *)
  | External_arrow          (** ◀ U+25C0 *)
  | Tool_square             (** ■ U+25A0 *)
  | Spark_mark              (** * U+002A *)
  | Warning_triangle        (** △ U+25B3 *)
  | Check_mark              (** ✓ U+2713 *)
  | Ellipsis                (** … U+2026 *)
  (* v2.5 Structural Accent, AI Reasoning & Cascade Primitives *)
  | Left_rail               (** ▎ U+258E — selection bar, Thinking/quote/callout rail *)
  | Ai_spark                (** ✦ U+2726 — AI Thinking trace / Candle economy mark *)
  | Flow_down               (** ↓ U+2193 — failover cascade step connector *)
  (* Tree & Box-Drawing Primitives *)
  | Tree_tee                (** ├ U+251C *)
  | Tree_corner             (** └ U+2514 *)
  | Tree_pipe               (** │ U+2502 *)
  | Box_tl                  (** ╭ U+256D *)
  | Box_tr                  (** ╮ U+256E *)
  | Box_bl                  (** ╰ U+2570 *)
  | Box_br                  (** ╯ U+256F *)
  | Box_h                   (** ─ U+2500 *)
  | Box_v                   (** │ U+2502 *)
  | Box_tee_l               (** ├ U+251C *)
  | Box_tee_r               (** ┤ U+2524 *)
  | Box_tee_t               (** ┬ U+252C *)
  | Box_tee_b               (** ┴ U+2534 *)
  | Box_cross               (** ┼ U+253C *)

val to_utf8 : t -> string
(** Unambiguous width-1 UTF-8 string for [t]. *)

val to_ascii_fallback : t -> string
(** Strict 1-cell printable ASCII fallback for degraded TTYs. *)

val all : t list
(** Exhaustive list covering every constructor and all 4 working frames. *)
