(** KvRow — atomic label/value row primitive (Bonsai mirror of Preact
    [kv-row.ts]).

    See [kv_row.mli] for the public contract.

    SPEC mapping (primitives.css [.kv-row]):
    - grid-template-columns: 80px 1fr  ([.is-wide] → 120px 1fr)
    - gap: var(--sp-3) (12px)
    - padding: 4px 0
    - align-items: baseline
    - font-size: 11px
    - .k → fg-muted, fs-10, uppercase, letter-spacing 0.06em
    - .v → fg-primary, mono, fs-11

    Mirrors the Preact [MONO_STACK] literal so the bonsai island
    renders the same monospace fallback chain as the Preact runtime. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .row {
    display: grid;
    grid-template-columns: 80px 1fr;
    gap: 12px;
    padding: 4px 0;
    align-items: baseline;
    font-size: var(--fs-11, 11px);
  }

  .row_wide {
    grid-template-columns: 120px 1fr;
  }

  .k {
    color: var(--color-fg-muted);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
  }

  .v {
    color: var(--color-fg-primary);
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
    font-size: var(--fs-11, 11px);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .v_wrap {
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    word-break: break-all;
  }
|}]

type width =
  [ `Default
  | `Wide
  ]

let width_class : width -> Attr.t list = function
  | `Default -> []
  | `Wide -> [ Style.row_wide ]
;;

let width_data_value : width -> string = function
  | `Default -> "false"
  | `Wide -> "true"
;;

let view
      ?(width = `Default)
      ?(wrap = false)
      ?value
      ?(children = [])
      ?testid
      ~label
      ()
  : Node.t
  =
  let row_attrs =
    let base =
      Style.row
      :: width_class width
      @ [ Attr.create "data-kv-row" ""
        ; Attr.create "data-kv-wide" (width_data_value width)
        ]
    in
    match testid with
    | Some id -> Attr.create "data-testid" id :: base
    | None -> base
  in
  let key =
    Node.span
      ~attrs:[ Style.k; Attr.create "data-kv-key" "" ]
      [ Node.text label ]
  in
  let value_node =
    match children with
    | _ :: _ -> Node.div children
    | [] ->
      let v_attrs =
        let base = [ Style.v; Attr.create "data-kv-value" "" ] in
        if wrap then Style.v_wrap :: base else base
      in
      Node.span ~attrs:v_attrs [ Node.text (Option.value value ~default:"") ]
  in
  Node.div ~attrs:row_attrs [ key; value_node ]
;;
