(** Pill — atomic primitive (Bonsai mirror of Preact [pill.ts]).

    Visual contract = SPEC §3.5 stateful surface + Preact PR #11157.
    16px capsule, translucent kind-tinted background at 0.12 alpha,
    optional 5px leading dot, computed [aria-label] / [role="status"].

    See [pill.ml] for full visual contract documentation including
    kind semantics and the Bonsai-only [`Brass] extension retained
    for legacy callers. *)

open! Bonsai_web
open Virtual_dom.Vdom

(** SPEC kinds (8 total). Mirrors Preact [PillKind] = neutral |
    running | paused | ok | warn | err | info | stalled, plus
    Bonsai-only [`Brass] for archive_runs "Completed" state. *)
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

(** Legacy color polyvar kept for backwards compatibility with
    archive_runs_view, goals_view, keepers_directory. New code should
    use [~kind] directly. [`Bad] maps to [`Err]. *)
type color =
  [ `Ok
  | `Warn
  | `Bad
  | `Brass
  | `Paused
  | `Neutral
  ]

(** Density selector. [`Md] (default) = 16px capsule per SPEC. [`Sm]
    = 14px compact variant for inline-dense tabs (goals). *)
type size =
  [ `Sm
  | `Md
  ]

(** [view ~label ()] renders an inline pill span.

    Kind selection precedence: [~kind] (new API) wins over [~color]
    (legacy). Default = [`Neutral] (chromeless baseline).

    [?dot] (default [false]): when [true] and kind is non-neutral,
    prepends a 5px round dot in the kind color. Auto-suppressed for
    [`Neutral] (no semantic state to flag).

    [?testid]: forwarded to [data-testid] for E2E selectors.

    [?aria_label]: overrides the auto-generated label
    ("LABEL (kind)"); pass when the host already conveys state.

    [?title]: native hover tooltip. *)
val view
  :  ?size:size
  -> ?color:color
  -> ?kind:kind
  -> ?dot:bool
  -> ?testid:string
  -> ?aria_label:string
  -> ?title:string
  -> label:string
  -> unit
  -> Node.t
