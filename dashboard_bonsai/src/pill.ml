(** Pill — atomic primitive (Bonsai mirror of Preact [pill.ts]).

    Visual contract = SPEC §3.5 stateful surface + Preact
    [dashboard/src/components/pill.ts] (PR #11157).

    Pill is the *stateful* sibling of Chip: same monospace-uppercase
    family, but rendered as a 16px capsule (rounded `border-radius:
    999px`, no border) with a translucent kind-tinted background at
    0.12 alpha. Use Pill when a thing transitions between states
    (running → paused, ok → warn). Use Chip for static labels.

    {1 Kind mapping}

    Eight kinds, mirroring Preact + a [`Brass] extension retained for
    Bonsai legacy callers (archive_runs, goals):

    - [`Neutral]: chromeless baseline, fg-secondary on bg-elevated.
    - [`Running]: accent-glow tint (matches `--color-accent-glow`).
    - [`Paused]: chromeless muted state (no glow, fg-muted).
    - [`Ok | `Warn | `Err | `Info | `Stalled]: status semantics with
      [rgb(var(--color-status-{kind}-glow) / 0.12)] translucent
      backgrounds (consume the glow tokens introduced in #11163).
    - [`Brass]: Bonsai-only highlighted accent (used by archive_runs
      "Completed" state). Uses [--color-accent-glow] triplet with
      [--color-accent-fg] foreground. Not present in Preact reference;
      retained here so the existing call sites (archive_runs_view,
      goals_view) keep working without code churn.

    {1 Dot variant}

    Optional 5px round leading dot in the kind color. Auto-suppressed
    when [kind = `Neutral] (no semantic state to flag), mirroring
    Preact behavior.

    {1 Backwards compatibility}

    Existing call sites use the legacy [~color] / [~size] surface
    ([`Ok | `Warn | `Bad | `Brass | `Paused | `Neutral] with [`Sm |
    `Md] sizes). Both legacy types remain; [`color] maps to [kind] via
    [color_to_kind] ([`Bad → `Err]). [size] is preserved but the new
    Preact-aligned default ([`Md]) renders the SPEC 16px capsule;
    [`Sm] keeps a 14px compact variant for the goals tab.

    {1 Accessibility}

    - [role="status"] when kind is non-neutral so screen readers
      announce state transitions.
    - Computed [aria-label] with kind suffix ("RUNNING (running)"),
      override via [?aria_label].
    - Optional [?title] for hover tooltips, [?testid] for E2E. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .pill_base {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    line-height: 1;
    border-radius: 999px;
    letter-spacing: 0.04em;
    text-transform: uppercase;
    font-weight: 500;
    white-space: nowrap;
  }

  .size_sm { height: 14px; padding: 0 7px; font-size: 9px;  }
  .size_md { height: 16px; padding: 0 8px; font-size: 10px; }

  .k_neutral {
    color: var(--color-fg-secondary, #c0a878);
    background: var(--color-bg-elevated, #1a1410);
  }
  .k_running {
    color: var(--color-accent-fg, #968228);
    background: rgb(var(--color-accent-glow, 150 130 40) / 0.12);
  }
  .k_paused {
    color: var(--color-fg-muted, #9a846e);
    background: var(--color-bg-elevated, #1a1410);
  }
  .k_ok {
    color: var(--color-status-ok, #6a9a4a);
    background: rgb(var(--color-status-ok-glow, 106 154 74) / 0.12);
  }
  .k_warn {
    color: var(--color-status-warn, #b87828);
    background: rgb(var(--color-status-warn-glow, 184 120 40) / 0.12);
  }
  .k_err {
    color: var(--color-status-err, #e85050);
    background: rgb(var(--color-status-err-glow, 232 80 80) / 0.12);
  }
  .k_info {
    color: var(--color-status-info, #968228);
    background: rgb(var(--color-status-info-glow, 150 130 40) / 0.12);
  }
  .k_stalled {
    color: var(--color-status-stalled, #8a6abf);
    background: rgb(var(--color-status-stalled-glow, 138 106 191) / 0.12);
  }
  .k_brass {
    color: var(--color-accent-fg, #968228);
    background: rgb(var(--color-accent-glow, 150 130 40) / 0.12);
  }

  .dot {
    display: inline-block;
    width: 5px;
    height: 5px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .dot_running { background: var(--color-accent-fg, #968228); }
  .dot_paused  { background: var(--color-fg-muted, #9a846e); }
  .dot_ok      { background: var(--color-status-ok, #6a9a4a); }
  .dot_warn    { background: var(--color-status-warn, #b87828); }
  .dot_err     { background: var(--color-status-err, #e85050); }
  .dot_info    { background: var(--color-status-info, #968228); }
  .dot_stalled { background: var(--color-status-stalled, #8a6abf); }
  .dot_brass   { background: var(--color-accent-fg, #968228); }

  @media (prefers-contrast: more) {
    .pill_base { border: 1px solid var(--text-bright); }
    .k_neutral { border-color: var(--text-bright); }
    .k_running { border-color: var(--color-accent-fg); }
    .k_paused  { border-color: var(--color-fg-muted); }
    .k_ok      { border-color: var(--color-status-ok); }
    .k_warn    { border-color: var(--color-status-warn); }
    .k_err     { border-color: var(--color-status-err); }
    .k_info    { border-color: var(--color-status-info); }
    .k_stalled { border-color: var(--color-status-stalled); }
    .k_brass   { border-color: var(--color-accent-fg); }
  }

  @media (forced-colors: active) {
    .pill_base { border: 1px solid ButtonText; }
    .k_neutral { border-color: GrayText; color: GrayText; }
    .k_running { border-color: Highlight; color: Highlight; }
    .k_paused  { border-color: GrayText; color: GrayText; }
    .k_ok      { border-color: Highlight; color: Highlight; }
    .k_warn    { border-color: Mark; color: Mark; }
    .k_err     { border-color: MarkText; color: MarkText; }
    .k_info    { border-color: Highlight; color: Highlight; }
    .k_stalled { border-color: ButtonText; color: ButtonText; }
    .k_brass   { border-color: ButtonText; color: ButtonText; }
  }
|}]

type kind =
  [ `Neutral
  | `Running
  | `Paused
  | `Ok
  | `Warn
  | `Err
  | `Info
  | `Stalled
  | `Brass
  ]

(** Legacy color polyvar kept so existing callers (archive_runs_view,
    goals_view, keepers_directory) compile unchanged. [`Bad] is the
    historical name for [`Err]. *)
type color =
  [ `Ok
  | `Warn
  | `Bad
  | `Brass
  | `Paused
  | `Neutral
  ]

type size =
  [ `Sm
  | `Md
  ]

let color_to_kind : color -> kind = function
  | `Ok -> `Ok
  | `Warn -> `Warn
  | `Bad -> `Err
  | `Brass -> `Brass
  | `Paused -> `Paused
  | `Neutral -> `Neutral
;;

let kind_class : kind -> Attr.t = function
  | `Neutral -> Style.k_neutral
  | `Running -> Style.k_running
  | `Paused -> Style.k_paused
  | `Ok -> Style.k_ok
  | `Warn -> Style.k_warn
  | `Err -> Style.k_err
  | `Info -> Style.k_info
  | `Stalled -> Style.k_stalled
  | `Brass -> Style.k_brass
;;

let size_class : size -> Attr.t = function
  | `Sm -> Style.size_sm
  | `Md -> Style.size_md
;;

let kind_data_attr : kind -> string = function
  | `Neutral -> "neutral"
  | `Running -> "running"
  | `Paused -> "paused"
  | `Ok -> "ok"
  | `Warn -> "warn"
  | `Err -> "err"
  | `Info -> "info"
  | `Stalled -> "stalled"
  | `Brass -> "brass"
;;

(** [`Neutral] suppresses dot (no semantic state to flag). Mirrors
    Preact behavior where [showDot = props.dot === true && kind !==
    'neutral']. *)
let dot_attr : kind -> Attr.t option = function
  | `Neutral -> None
  | `Running -> Some Style.dot_running
  | `Paused -> Some Style.dot_paused
  | `Ok -> Some Style.dot_ok
  | `Warn -> Some Style.dot_warn
  | `Err -> Some Style.dot_err
  | `Info -> Some Style.dot_info
  | `Stalled -> Some Style.dot_stalled
  | `Brass -> Some Style.dot_brass
;;

let kind_announce : kind -> string option = function
  | `Neutral -> None
  | `Running -> Some "running"
  | `Paused -> Some "paused"
  | `Ok -> Some "ok"
  | `Warn -> Some "warning"
  | `Err -> Some "failing"
  | `Info -> Some "info"
  | `Stalled -> Some "stalled"
  | `Brass -> Some "completed"
;;

(** Pure: assemble the screen-reader label. [`Neutral] returns content
    as-is; stateful kinds append "(<announce>)" suffix. Mirrors Preact
    [pillAriaLabel]. *)
let aria_label_of ?aria_label ~(kind : kind) (label : string) : string =
  match aria_label with
  | Some explicit -> explicit
  | None ->
    (match kind_announce kind with
     | None -> label
     | Some suffix -> label ^ " (" ^ suffix ^ ")")
;;

let view
      ?(size : size = `Md)
      ?(color : color = `Neutral)
      ?(kind : kind option)
      ?(dot : bool = false)
      ?testid
      ?aria_label
      ?title
      ~(label : string)
      ()
  : Node.t
  =
  let resolved_kind : kind =
    match kind with
    | Some k -> k
    | None -> color_to_kind color
  in
  let show_dot = dot && not (Poly.equal resolved_kind `Neutral) in
  let aria = aria_label_of ?aria_label ~kind:resolved_kind label in
  let role_attr =
    if Poly.equal resolved_kind `Neutral
    then []
    else [ Attr.create "role" "status" ]
  in
  let testid_attr =
    match testid with
    | Some t -> [ Attr.create "data-testid" t ]
    | None -> []
  in
  let title_attr =
    match title with
    | Some t -> [ Attr.create "title" t ]
    | None -> []
  in
  let attrs =
    [ Style.pill_base
    ; size_class size
    ; kind_class resolved_kind
    ; Attr.create "data-kind" (kind_data_attr resolved_kind)
    ; Attr.create "aria-label" aria
    ]
    @ role_attr
    @ testid_attr
    @ title_attr
  in
  let dot_node =
    if show_dot
    then (
      match dot_attr resolved_kind with
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
