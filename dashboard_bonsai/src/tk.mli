(** Tk — atomic inline mono highlight (Bonsai mirror of Preact [tk.ts],
    PR #11200 atom 9~10/14).

    SPEC primitives.css [.tk]: a small mono-font chunk on a tinted
    background, used to mark identifier-shaped tokens inside running
    prose: env var names, file paths, agent ids, error codes, command
    flags. Reads like inline code in technical writing.

    Distinct from sibling primitives:
    - [Kbd] — keyboard shortcut indicator (3D key cap).
    - [Chip] / [Pill] — semantic state labels (Tk has no state).
    - Block-level command snippets — different layout, not inline.

    Visual contract = SPEC primitives.css [.tk] + [.tk.is-brass] +
    [.tk.is-err] + Preact reference [dashboard/src/components/tk.ts]. *)

open! Bonsai_web
open Virtual_dom.Vdom

type kind =
  [ `Default
  | `Brass (** [.tk.is-brass] — accent fg + 0.08 accent-glow bg. *)
  | `Err (** [.tk.is-err] — err fg + 0.08 err-glow bg. *)
  ]

type tag =
  [ `Code (** Default. Semantic match for inline code fragments. *)
  | `Span (** Use when nesting inside [<code>] / [<pre>]. *)
  ]

(** [view ?kind ?tag ?testid ?title ~children ()] renders the inline
    token highlight.

    [kind] (default [`Default]): tone variant. SPEC has only the three
    listed tones; warn / info / stalled are not in SPEC for [.tk].

    [tag] (default [`Code]): rendered HTML element. Override to
    [`Span] when the surrounding context is itself inside [<code>] /
    [<pre>] and nesting would be invalid.

    [testid]: forwarded to [data-testid].

    [title]: native [title] attribute for hover tooltips. The
    primitive itself is non-interactive — wrap in a button if click
    is needed. *)
val view
  :  ?kind:kind
  -> ?tag:tag
  -> ?testid:string
  -> ?title:string
  -> children:Node.t list
  -> unit
  -> Node.t
