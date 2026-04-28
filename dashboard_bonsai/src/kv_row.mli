(** KvRow — atomic label/value row primitive (Bonsai mirror of Preact
    [kv-row.ts], PR #11178 atom 6/14).

    SPEC primitives.css [.kv-row]: a single label / value row with a
    fixed-width label column, baseline alignment, uppercase muted
    label, and a mono value in primary fg. Used inside drawer details,
    inspector panels, keeper-detail KV strips — anywhere a screen
    says "here are the metadata facts about this thing".

    Distinct from sibling primitives:
    - [Sep] — visual divider between siblings, no semantic content.
    - [Pill] / [Chip] — tag-like small badges, value-first.
    - [Caps] / [Tk] — typographic atoms, single-line text shaping.

    Visual contract = SPEC primitives.css [.kv-row] / [.kv-row.is-wide]
    selectors + Preact reference [dashboard/src/components/kv-row.ts]. *)

open! Bonsai_web
open Virtual_dom.Vdom

type width =
  [ `Default (** 80px label column. *)
  | `Wide (** 120px label column ([.kv-row.is-wide]). *)
  ]

(** [view ?width ?wrap ?value ?children ?testid ~label ()] renders the
    row.

    [width] (default [`Default]): see {!type:width}.

    [wrap] (default [false]): allow long values to wrap on word
    boundaries. SPEC default is whitespace:nowrap with ellipsis
    overflow; long ids / paths often need wrap.

    [value]: SPEC mono value text. Ignored when [children] is non-empty.

    [children] (default [[]]): rich value content (chips, pills,
    links). Caller controls typography. When non-empty, [value] is
    ignored.

    [testid]: forwarded to [data-testid] on the row container.

    [label]: required. Rendered uppercase via the SPEC font rule.

    Renders a [<div data-kv-row>] with [<span data-kv-key>] +
    value cell. *)
val view
  :  ?width:width
  -> ?wrap:bool
  -> ?value:string
  -> ?children:Node.t list
  -> ?testid:string
  -> label:string
  -> unit
  -> Node.t
