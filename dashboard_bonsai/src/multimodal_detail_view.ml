(** Tier F2 — detail panel for the currently-selected artifact.

    Renders below the gallery grid when [selected_id_var] is [Some _].
    Reads three vars reactively:
    - [selected_id_var] : [string option]   (controls visibility + close)
    - [detail_var]      : [detail option]   ([/get] result)
    - [provenance_var]  : [provenance option] ([/provenance] result)

    A close button clears all three vars via [Multimodal_detail_fetch.clear].
    No payload-kind-specific rendering — payload + metadata are
    pretty-printed JSON for operator inspection. Provenance is a flat
    list of origin/descendant ids; F2 does not yet render a DAG. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .panel {
    margin-top: 1.5rem;
    padding: 1.5rem;
    background: var(--color-bg-surface);
    border: 1px solid var(--color-border-default);
    border-radius: 6px;
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }
  .head {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
  }
  .head_left { display: flex; align-items: baseline; gap: 0.75rem; }
  .head_title {
    font-family: 'Cinzel', serif;
    font-weight: 500;
    font-size: 1rem;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--text-bright);
    margin: 0;
  }
  .head_id {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, monospace;
    font-size: 0.8rem;
    color: var(--color-fg-muted);
  }
  .close_btn {
    background: transparent;
    border: 1px solid var(--color-border-default);
    color: var(--color-fg-muted);
    border-radius: 3px;
    padding: 4px 10px;
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.7rem;
    cursor: pointer;
    letter-spacing: 0.08em;
  }
  .close_btn:hover { color: var(--text-bright); }
  .section_title {
    font-family: 'Cinzel', serif;
    font-size: 0.75rem;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    margin: 0 0 0.4rem 0;
  }
  .json {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.75rem;
    color: var(--color-fg-primary);
    background: color-mix(in oklab, var(--color-bg-page) 50%, transparent);
    padding: 0.75rem;
    border-radius: 4px;
    border: 1px solid color-mix(in oklab, var(--color-border-default) 60%, transparent);
    white-space: pre-wrap;
    word-break: break-all;
    max-height: 320px;
    overflow: auto;
    margin: 0;
  }
  .prov_grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1rem;
  }
  .prov_list {
    list-style: none;
    padding: 0;
    margin: 0;
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.75rem;
    color: var(--color-fg-primary);
  }
  .prov_list li {
    padding: 2px 0;
    border-bottom: 1px solid color-mix(in oklab, var(--color-border-default) 30%, transparent);
  }
  .prov_empty {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }
  .loading {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    color: var(--color-fg-muted);
  }
  .not_found {
    font-family: 'EB Garamond', Georgia, serif;
    color: var(--color-fg-muted);
    padding: 0.75rem;
    border: 1px dashed color-mix(in oklab, var(--color-border-default) 70%, transparent);
    border-radius: 4px;
    text-align: center;
  }
  .error {
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.8rem;
    color: var(--text-bright);
    background: color-mix(in oklab, var(--accent-blood) 18%, transparent);
    border: 1px solid color-mix(in oklab, var(--accent-blood) 50%, transparent);
    padding: 0.6rem 0.75rem;
    border-radius: 4px;
  }
  .created_by {
    font-family: 'EB Garamond', Georgia, serif;
    font-style: italic;
    color: var(--color-fg-muted);
    font-size: 0.85rem;
  }
|}]

let close_button : Node.t =
  Node.button
    ~attrs:
      [ Style.close_btn
      ; Attr.on_click (fun _ ->
            Multimodal_detail_fetch.clear ();
            Effect.Ignore)
      ]
    [ Node.text "close" ]
;;

let render_detail (d : Multimodal_detail_types.detail) : Node.t list =
  [ Node.div
      ~attrs:[ Style.head ]
      [ Node.div
          ~attrs:[ Style.head_left ]
          [ Node.h2 ~attrs:[ Style.head_title ] [ Node.text d.kind ]
          ; Node.span ~attrs:[ Style.head_id ] [ Node.text d.id ]
          ]
      ; close_button
      ]
  ; (if String.is_empty d.created_by then Node.none
     else
       Node.div
         ~attrs:[ Style.created_by ]
         [ Node.text ("created by " ^ d.created_by) ])
  ; Node.div
      [ Node.h3 ~attrs:[ Style.section_title ] [ Node.text "payload" ]
      ; Node.pre ~attrs:[ Style.json ] [ Node.text d.payload_pretty ]
      ]
  ; Node.div
      [ Node.h3 ~attrs:[ Style.section_title ] [ Node.text "metadata" ]
      ; Node.pre ~attrs:[ Style.json ] [ Node.text d.metadata_pretty ]
      ]
  ]
;;

let render_id_list (ids : string list) : Node.t =
  if List.is_empty ids
  then Node.span ~attrs:[ Style.prov_empty ] [ Node.text "(none)" ]
  else
    Node.ul
      ~attrs:[ Style.prov_list ]
      (List.map ids ~f:(fun id -> Node.li [ Node.text id ]))
;;

let render_provenance (p : Multimodal_detail_types.provenance) : Node.t =
  Node.div
    [ Node.h3 ~attrs:[ Style.section_title ] [ Node.text "provenance" ]
    ; Node.div
        ~attrs:[ Style.prov_grid ]
        [ Node.div
            [ Node.div ~attrs:[ Style.section_title ] [ Node.text "origins" ]
            ; render_id_list p.origins
            ]
        ; Node.div
            [ Node.div ~attrs:[ Style.section_title ] [ Node.text "descendants" ]
            ; render_id_list p.descendants
            ]
        ]
    ]
;;

module T = Multimodal_detail_types

let header_for_id (id : string) : Node.t =
  Node.div
    ~attrs:[ Style.head ]
    [ Node.div
        ~attrs:[ Style.head_left ]
        [ Node.span ~attrs:[ Style.head_id ] [ Node.text id ] ]
    ; close_button
    ]
;;

(** Detail-side rendering for each fetch_state. When the state is
    [Loaded d], we use [render_detail d] which embeds its own header
    (with kind + id). All other states fall back to a simple
    id-only header so the close button stays available. *)
let render_detail_state
    ~(id : string)
    (state : T.detail T.fetch_state)
    : Node.t list
  =
  match state with
  | T.Loaded d -> render_detail d
  | T.Loading ->
    [ header_for_id id
    ; Node.div ~attrs:[ Style.loading ] [ Node.text "loading detail…" ]
    ]
  | T.Idle ->
    (* Defensive — should not occur while selected_id is Some,
       but render close-able header so the operator can clear. *)
    [ header_for_id id ]
  | T.NotFound ->
    [ header_for_id id
    ; Node.div
        ~attrs:[ Style.not_found ]
        [ Node.text "artifact not found" ]
    ]
  | T.Error msg ->
    [ header_for_id id
    ; Node.div
        ~attrs:[ Style.error ]
        [ Node.text ("detail unavailable: " ^ msg) ]
    ]
;;

let render_provenance_state
    (state : T.provenance T.fetch_state)
    : Node.t
  =
  match state with
  | T.Loaded p -> render_provenance p
  | T.Loading ->
    Node.div
      ~attrs:[ Style.loading ]
      [ Node.text "loading provenance…" ]
  | T.Idle -> Node.none
  | T.NotFound ->
    Node.div
      ~attrs:[ Style.not_found ]
      [ Node.text "no provenance recorded" ]
  | T.Error msg ->
    Node.div
      ~attrs:[ Style.error ]
      [ Node.text ("provenance unavailable: " ^ msg) ]
;;

let view_of_state
    ~(selected_id : string option)
    ~(detail : T.detail T.fetch_state)
    ~(provenance : T.provenance T.fetch_state)
    : Node.t
  =
  match selected_id with
  | None -> Node.none
  | Some id ->
    let body = render_detail_state ~id detail in
    let prov_section = render_provenance_state provenance in
    Node.div ~attrs:[ Style.panel ] (body @ [ prov_section ])
;;

let component (_graph @ local) =
  let%map.Bonsai selected_id =
    Bonsai.Expert.Var.value Multimodal_detail_var.selected_id_var
  and detail = Bonsai.Expert.Var.value Multimodal_detail_var.detail_var
  and provenance =
    Bonsai.Expert.Var.value Multimodal_detail_var.provenance_var
  in
  view_of_state ~selected_id ~detail ~provenance
;;
