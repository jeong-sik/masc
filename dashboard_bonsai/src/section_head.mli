(** SectionHead — atomic panel header strip primitive (Bonsai mirror of
    Preact [section-head.ts], PR #11176 atom 5/14).

    SPEC primitives.css [.section-head]: 28px panel header strip with
    uppercase label on the left, optional count or arbitrary tail
    content right-aligned, and a hairline border-bottom separating the
    head from the body of a card / panel.

    Distinct from sibling primitives:
    - [section_cap] (when ported) — pure label *style*, no surface, no
      flex layout.
    - [section_header] (when ported) — flex container with heading +
      right slot, but no border-bottom, no surface, no 28px min-height.
    - [SectionHead] (this module) — full SPEC: strip surface (bg +
      border-bottom + min-height + padding) + uppercase label + count
      / tail right slot.

    Visual contract = SPEC primitives.css [.section-head] selectors +
    Preact reference [dashboard/src/components/section-head.ts]. *)

open! Bonsai_web
open Virtual_dom.Vdom

(** [view ?count ?tail ?no_border ?testid ?aria_label ~label ()]
    renders the header strip.

    [label]: required. Label content (typically text). Rendered
    uppercase via SPEC font rule. Pass a list of nodes when the label
    needs inline shaping (icon + text, etc.).

    [count] (optional): right-aligned numeric badge. Rendered with
    tabular-nums + fg-disabled tone (SPEC [.count]). Pass a pre-
    formatted string ([Int.to_string n] for integer counts).

    [tail] (optional): right-aligned arbitrary content (Pill, Chip,
    button row). Compatible with [count]: count renders first, tail
    after, both inside the same right-flex container.

    [no_border] (default [false]): drop the bottom hairline. Useful
    when the head sits above a custom divider or another strip.

    [testid]: forwarded to [data-testid] on the host.

    [aria_label]: override the auto aria-label. Default no aria — the
    heading text is read directly.

    Renders a [<div>] with flex layout. *)
val view
  :  ?count:string
  -> ?tail:Node.t list
  -> ?no_border:bool
  -> ?testid:string
  -> ?aria_label:string
  -> label:Node.t list
  -> unit
  -> Node.t
