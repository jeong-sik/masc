(** SectionHead — atomic panel header strip (Bonsai mirror of Preact
    [section-head.ts]).

    See [section_head.mli] for the public contract.

    SPEC mapping (primitives.css [.section-head]):
    - min-height 28px, padding 0 12px
    - border-bottom 1px solid [--color-border-default]
    - background [--color-bg-surface]
    - font-size 11px, weight 600, letter-spacing 0.08em, uppercase
    - color [--color-fg-muted]

    Right slot via [.count] (tabular-nums, fg-disabled) or [.tail]
    (flex container) — both push to right with [margin-left:auto].
    [count] is rendered with the same MONO_STACK literal as Preact
    so both runtimes resolve to the same monospace fallback chain.

    [no_border] uses longhand [border-bottom-{width,style,color}]
    explicitly — happy-dom (Preact tests) misparses the [border-bottom]
    shorthand when combined with [var(--token)], splitting the var
    across all three sub-properties. The Preact reference uses
    longhand for the same reason; the bonsai mirror keeps the same
    pattern for byte-exact CSS parity. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .head {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 28px;
    padding: 0 12px;
    border-bottom-width: 1px;
    border-bottom-style: solid;
    border-bottom-color: var(--color-border-default);
    background: var(--color-bg-surface);
    font-size: var(--fs-11, 11px);
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    flex-shrink: 0;
  }

  .head_no_border {
    border-bottom-width: 0;
    border-bottom-style: none;
    border-bottom-color: transparent;
  }

  .label {
    flex-shrink: 0;
  }

  .count {
    margin-left: auto;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    color: var(--color-fg-disabled);
    font-weight: 500;
    font-variant-numeric: tabular-nums;
  }

  /* When count is present, tail sits 8px to its right; otherwise
     tail itself takes the margin-left:auto right-push role. */
  .tail_with_count {
    margin-left: 8px;
    display: inline-flex;
    gap: 4px;
    align-items: center;
  }

  .tail_no_count {
    margin-left: auto;
    display: inline-flex;
    gap: 4px;
    align-items: center;
  }
|}]

let view
      ?count
      ?tail
      ?(no_border = false)
      ?testid
      ?aria_label
      ~label
      ()
  : Node.t
  =
  let host_attrs =
    let base =
      if no_border
      then [ Style.head; Style.head_no_border ]
      else [ Style.head ]
    in
    let with_testid =
      match testid with
      | Some id -> Attr.create "data-testid" id :: base
      | None -> base
    in
    match aria_label with
    | Some s -> Attr.create "aria-label" s :: with_testid
    | None -> with_testid
  in
  let label_node = Node.span ~attrs:[ Style.label ] label in
  let count_node =
    match count with
    | Some s ->
      Some
        (Node.span
           ~attrs:[ Style.count; Attr.create "data-section-head-count" "" ]
           [ Node.text s ])
    | None -> None
  in
  let tail_node =
    match tail with
    | Some children ->
      let tail_class =
        match count with
        | Some _ -> Style.tail_with_count
        | None -> Style.tail_no_count
      in
      Some
        (Node.span
           ~attrs:[ tail_class; Attr.create "data-section-head-tail" "" ]
           children)
    | None -> None
  in
  let body =
    label_node :: List.filter_opt [ count_node; tail_node ]
  in
  Node.div ~attrs:host_attrs body
;;
