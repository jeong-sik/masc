(** Chip — atomic primitive (Bonsai mirror of Preact [chip.ts]).

    Visual contract = SPEC §3.5 status + Preact PR #11153 / #11173.
    8 kinds × 3 sizes + leading dot variant. See [chip.ml] for full
    visual contract documentation. *)

open! Bonsai_web
open Virtual_dom.Vdom

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

(** [view ?dot ~kind ~size label] renders an inline chip span.

    [dot] (default [false]): when [true] and [kind] has a semantic
    color (anything except [`Idle] / [`Neutral]), prepends a 5px round
    dot in the kind color. Auto-suppressed for [`Idle] / [`Neutral]
    because they have no semantic color worth surfacing.

    [kind]: tone selector. See SPEC §3.5 for canonical semantics.

    [size]: density selector. [`Sm] = 14px / 9px font, [`Md] = 18px /
    10px font, [`Lg] = 22px / 11px font. *)
val view : ?dot:bool -> kind:kind -> size:size -> string -> Node.t
