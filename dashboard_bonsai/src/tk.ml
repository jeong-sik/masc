(** Tk — atomic inline mono highlight (Bonsai mirror of Preact [tk.ts]).

    See [tk.mli] for the public contract.

    SPEC mapping (primitives.css [.tk]):
    - font-family [--font-mono] (mirrored as the same MONO_STACK
      literal as Preact, see below)
    - font-size 0.92em (relative — sits in surrounding prose)
    - padding 0 4px
    - border-radius 2px
    - default → bg [--color-bg-elevated], fg [--color-fg-primary]
    - [.is-brass] → fg [--color-accent-fg], bg
      [rgb(var(--color-accent-glow) / 0.08)]
    - [.is-err] → fg [--color-status-err], bg
      [rgb(var(--color-status-err-glow) / 0.08)]

    Inline content. Whitespace is forced to nowrap with overflow
    hidden + ellipsis so a 2KB path inside a row does not blow up
    layout — same defensive shaping the Preact reference applies. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .tk_base {
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    font-size: 0.92em;
    padding: 0 4px;
    border-radius: 2px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    vertical-align: baseline;
    max-width: 100%;
  }

  .kind_default {
    background: var(--color-bg-elevated);
    color: var(--color-fg-primary);
  }

  .kind_brass {
    background: rgb(var(--color-accent-glow) / 0.08);
    color: var(--color-accent-fg);
  }

  .kind_err {
    background: rgb(var(--color-status-err-glow) / 0.08);
    color: var(--color-status-err);
  }
|}]

type kind =
  [ `Default
  | `Brass
  | `Err
  ]

type tag =
  [ `Code
  | `Span
  ]

let kind_class : kind -> Attr.t = function
  | `Default -> Style.kind_default
  | `Brass -> Style.kind_brass
  | `Err -> Style.kind_err
;;

let kind_name : kind -> string = function
  | `Default -> "default"
  | `Brass -> "brass"
  | `Err -> "err"
;;

let tag_name : tag -> string = function
  | `Code -> "code"
  | `Span -> "span"
;;

let view
      ?(kind = `Default)
      ?(tag = `Code)
      ?testid
      ?title
      ~children
      ()
  : Node.t
  =
  let attrs =
    let base =
      [ Style.tk_base
      ; kind_class kind
      ; Attr.create "data-tk" ""
      ; Attr.create "data-kind" (kind_name kind)
      ]
    in
    let with_testid =
      match testid with
      | Some id -> Attr.create "data-testid" id :: base
      | None -> base
    in
    match title with
    | Some t -> Attr.create "title" t :: with_testid
    | None -> with_testid
  in
  Node.create (tag_name tag) ~attrs children
;;
