(** Pill primitive — MASC Design System 상태 pill.

    Archive_runs (status pill 6 variant) 와 Goals (status_pill) 에서
    반복되던 border + uppercase + letter-spacing 박스를 하나로 통합.

    [size] 는 탭별 밀도 차이를 수용:
    - [`Md] : font 11px / padding 4px 8px  (archive_runs 기본)
    - [`Sm] : font 11px / padding 2px 6px  (goals inline compact)

    [color] 는 Meta와 동일한 4색 + status-specific 2색:
    - [`Ok]      live/active/running        (status-ok, green)
    - [`Warn]    paused                     (status-warn, amber)
    - [`Bad]     failed/dead                (accent-blood)
    - [`Brass]   completed/done             (accent-brass)
    - [`Paused]  stopped/skipped            (text-dim)
    - [`Neutral] unknown/fallback           (border-main base only)

    탭별 status enum → color 매핑은 caller 책임. primitive는 색만
    주입한다. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .pill_md {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    padding: 4px 8px;
    text-align: center;
    border: 1px solid var(--border-main, #3a2e20);
    font-variant-numeric: tabular-nums;
    color: var(--text-dim, #9a846e);
  }

  .pill_sm {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 11px;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    padding: 2px 6px;
    border: 1px solid var(--border-main, #3a2e20);
    text-align: center;
    color: var(--text-dim, #9a846e);
  }

  .c_ok      { color: var(--status-ok, #6a9a4a); border-color: var(--status-ok, #6a9a4a); }
  .c_warn    { color: var(--status-warn, #b87828); border-color: var(--status-warn, #b87828); }
  .c_bad     { color: var(--accent-blood, #e85050); border-color: var(--accent-blood, #e85050); }
  .c_brass   { color: var(--accent-brass, #968228); border-color: var(--accent-brass, #968228); }
  .c_paused  { color: var(--text-dim, #9a846e); border-color: var(--border-main, #3a2e20); }
  .c_neutral { color: var(--text-dim, #9a846e); border-color: var(--border-main, #3a2e20); }
|}]

type size = [ `Sm | `Md ]
type color = [ `Ok | `Warn | `Bad | `Brass | `Paused | `Neutral ]

let view ?(size : size = `Md) ?(color : color = `Neutral)
      ~(label : string) () : Node.t =
  let base =
    match size with
    | `Md -> Style.pill_md
    | `Sm -> Style.pill_sm
  in
  let c =
    match color with
    | `Ok -> Style.c_ok
    | `Warn -> Style.c_warn
    | `Bad -> Style.c_bad
    | `Brass -> Style.c_brass
    | `Paused -> Style.c_paused
    | `Neutral -> Style.c_neutral
  in
  Node.span ~attrs:[ base; c ] [ Node.text label ]
;;
