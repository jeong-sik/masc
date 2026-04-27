(** Chip — atomic primitive (Bonsai mirror of Preact [chip.ts]).

    Visual contract = SPEC §3.5 status (data, not chrome) + Preact
    [dashboard/src/components/chip.ts] (PR #11153 / #11173).

    8 kinds × 3 sizes + leading dot. Background uses
    [rgb(var(--color-status-{kind}-glow) / 0.10)] translucent glow
    pattern; foreground uses [var(--color-status-{kind})]; border uses
    [rgb(var(--color-status-{kind}-glow) / 0.35)].

    Kind mapping (mission spec polyvars):
    - [`Ok | `Warn | `Err | `Info | `Stalled]: status semantics with
      glow tokens (consume [--color-status-{kind}-glow] introduced in
      #11163).
    - [`Idle]: silent state, no glow (SPEC §3.5: idle has no chrome).
      Foreground = [--color-status-idle], chromeless background.
    - [`Brass]: highlighted accent, uses [--color-accent-glow] triplet
      with [--color-accent-fg] / [--color-accent-fg-dim] border.
    - [`Neutral]: baseline chromeless, uses fg-secondary / border-default
      / bg-elevated (matches Preact reference).

    Dot variant: 5px round dot in kind color, suppressed for [`Neutral]
    and [`Idle] (no semantic color to show, mirrors Preact ghost/neutral
    suppression). *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .chip_base {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    line-height: 1;
    border-radius: 2px;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    font-weight: 500;
    white-space: nowrap;
    border-style: solid;
    border-width: 1px;
  }

  .size_sm  { height: 14px; padding: 0 5px; font-size: 9px;  }
  .size_md  { height: 18px; padding: 0 7px; font-size: 10px; }
  .size_lg  { height: 22px; padding: 0 9px; font-size: 11px; }

  .k_ok {
    color: var(--color-status-ok, #6a9a4a);
    border-color: rgb(var(--color-status-ok-glow, 106 154 74) / 0.35);
    background: rgb(var(--color-status-ok-glow, 106 154 74) / 0.10);
  }
  .k_warn {
    color: var(--color-status-warn, #b87828);
    border-color: rgb(var(--color-status-warn-glow, 184 120 40) / 0.35);
    background: rgb(var(--color-status-warn-glow, 184 120 40) / 0.10);
  }
  .k_err {
    color: var(--color-status-err, #e85050);
    border-color: rgb(var(--color-status-err-glow, 232 80 80) / 0.35);
    background: rgb(var(--color-status-err-glow, 232 80 80) / 0.10);
  }
  .k_info {
    color: var(--color-status-info, #968228);
    border-color: rgb(var(--color-status-info-glow, 150 130 40) / 0.35);
    background: rgb(var(--color-status-info-glow, 150 130 40) / 0.10);
  }
  .k_idle {
    color: var(--color-status-idle, #807870);
    border-color: var(--color-border-default, #3a2e20);
    background: transparent;
  }
  .k_stalled {
    color: var(--color-status-stalled, #8a6abf);
    border-color: rgb(var(--color-status-stalled-glow, 138 106 191) / 0.35);
    background: rgb(var(--color-status-stalled-glow, 138 106 191) / 0.10);
  }
  .k_brass {
    color: var(--color-accent-fg, #968228);
    border-color: var(--color-accent-fg-dim, #4d4115);
    background: rgb(var(--color-accent-glow, 150 130 40) / 0.10);
  }
  .k_neutral {
    color: var(--color-fg-secondary, #c0a878);
    border-color: var(--color-border-default, #3a2e20);
    background: var(--color-bg-elevated, #1a1410);
  }

  .dot {
    display: inline-block;
    width: 5px;
    height: 5px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .dot_ok      { background: var(--color-status-ok, #6a9a4a); }
  .dot_warn    { background: var(--color-status-warn, #b87828); }
  .dot_err     { background: var(--color-status-err, #e85050); }
  .dot_info    { background: var(--color-status-info, #968228); }
  .dot_stalled { background: var(--color-status-stalled, #8a6abf); }
  .dot_brass   { background: var(--color-accent-fg, #968228); }

  @media (prefers-contrast: more) {
    .chip_base { border-width: 2px; }
    .k_ok      { border-color: var(--color-status-ok); }
    .k_warn    { border-color: var(--color-status-warn); }
    .k_err     { border-color: var(--color-status-err); }
    .k_info    { border-color: var(--color-status-info); }
    .k_idle    { border-color: var(--text-bright); }
    .k_stalled { border-color: var(--color-status-stalled); }
    .k_brass   { border-color: var(--color-accent-fg); }
    .k_neutral { border-color: var(--text-bright); }
  }

  @media (forced-colors: active) {
    .chip_base { border-color: ButtonText; }
    .k_ok      { border-color: Highlight; color: Highlight; }
    .k_warn    { border-color: Mark; color: Mark; }
    .k_err     { border-color: MarkText; color: MarkText; }
    .k_info    { border-color: Highlight; color: Highlight; }
    .k_idle    { border-color: GrayText; color: GrayText; }
    .k_stalled { border-color: ButtonText; color: ButtonText; }
    .k_brass   { border-color: ButtonText; color: ButtonText; }
    .k_neutral { border-color: GrayText; color: GrayText; }
  }
|}]

type kind =
  [ `Ok
  | `Warn
  | `Err
  | `Info
  | `Idle
  | `Stalled
  | `Brass
  | `Neutral
  ]

type size =
  [ `Sm
  | `Md
  | `Lg
  ]

let kind_class : kind -> Attr.t = function
  | `Ok -> Style.k_ok
  | `Warn -> Style.k_warn
  | `Err -> Style.k_err
  | `Info -> Style.k_info
  | `Idle -> Style.k_idle
  | `Stalled -> Style.k_stalled
  | `Brass -> Style.k_brass
  | `Neutral -> Style.k_neutral
;;

let size_class : size -> Attr.t = function
  | `Sm -> Style.size_sm
  | `Md -> Style.size_md
  | `Lg -> Style.size_lg
;;

(** [`Neutral] and [`Idle] have no semantic accent color worth surfacing
    as a leading dot; mirrors Preact reference (neutral/ghost suppress
    dot). *)
let dot_attr : kind -> Attr.t option = function
  | `Ok -> Some Style.dot_ok
  | `Warn -> Some Style.dot_warn
  | `Err -> Some Style.dot_err
  | `Info -> Some Style.dot_info
  | `Stalled -> Some Style.dot_stalled
  | `Brass -> Some Style.dot_brass
  | `Idle | `Neutral -> None
;;

let view ?(dot = false) ~(kind : kind) ~(size : size) (label : string) : Node.t
  =
  let attrs =
    [ Style.chip_base
    ; size_class size
    ; kind_class kind
    ; Attr.create "data-kind"
        (match kind with
         | `Ok -> "ok"
         | `Warn -> "warn"
         | `Err -> "err"
         | `Info -> "info"
         | `Idle -> "idle"
         | `Stalled -> "stalled"
         | `Brass -> "brass"
         | `Neutral -> "neutral")
    ; Attr.create "data-size"
        (match size with
         | `Sm -> "sm"
         | `Md -> "md"
         | `Lg -> "lg")
    ]
  in
  let dot_node =
    if dot
    then (
      match dot_attr kind with
      | Some d ->
        [ Node.span
            ~attrs:[ Style.dot; d; Attr.create "aria-hidden" "true" ]
            []
        ]
      | None -> [])
    else []
  in
  Node.span ~attrs (dot_node @ [ Node.text label ])
;;
