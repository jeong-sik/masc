(** Dot — atomic round status / keeper-slot indicator (Bonsai primitive).

    A 4px round dot consumed in dense surfaces (status pills, keeper roster
    rows, table cells) where chip-level chrome is too heavy. No standalone
    Preact equivalent exists; the dot rendering is extracted from
    [dashboard/src/components/chip.ts] (the [dot] prop section, 5px) and
    promoted to a standalone primitive at the SPEC §primitives 4px tier so
    callers can attribute state without dragging chip text/border in.

    Two attribution axes:
    - [`Status of [`Ok | `Warn | `Err | `Info | `Idle | `Stalled]] — semantic
      state indicator. Color from [--color-status-{kind}]; outer glow from
      [rgb(var(--color-status-{kind}-glow) / 0.5)] at 5px radius. [`Idle]
      has no glow (SPEC §3.5 silent state, no chrome).
    - [`Keeper_slot of int] — per-keeper attribution (1..12). Color from
      [--color-keeper-N]; outer glow from [rgb(var(--k-N-glow) / 0.5)] at
      5px radius (mirrors the canonical [.dot-k-N] selector in
      [design-system/source_styles/tokens.css]). Out-of-range slots clamp
      to a neutral grey dot with [data-slot=oob] so audits can catch
      malformed callers (precedent: [Keeper_badge]).

    Sizes:
    - default (no arg) — 4px round (SPEC §primitives default tier).
    - [`Sm] — 3px round (table-cell density).
    - [`Md] — 6px round (matches the inline [.dot] selector in
      [tokens.css:420], the larger inline-flow dot used in chip text). *)

open! Bonsai_web
open Virtual_dom.Vdom

type kind =
  [ `Status of
    [ `Ok
    | `Warn
    | `Err
    | `Info
    | `Idle
    | `Stalled
    ]
  | `Keeper_slot of int
  ]

type size =
  [ `Sm
  | `Md
  ]

(** [view ~kind ()] renders a round dot.

    [kind]: see {!type:kind}. [`Status `Idle] renders without a glow;
    every other status / keeper slot renders with an outer glow at
    0.5 alpha and 5px radius. Out-of-range [`Keeper_slot N] clamps to a
    neutral grey dot tagged [data-slot=oob].

    [size]: omit for the default 4px round; pass [`Sm] for 3px (dense
    rows) or [`Md] for 6px (inline flow with text). *)
val view : ?size:size -> kind:kind -> unit -> Node.t
