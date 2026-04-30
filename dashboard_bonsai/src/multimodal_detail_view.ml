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

let view_of_state
    ~(selected_id : string option)
    ~(detail : Multimodal_detail_types.detail option)
    ~(provenance : Multimodal_detail_types.provenance option)
    : Node.t
  =
  match selected_id with
  | None -> Node.none
  | Some id ->
    let header_when_loading =
      Node.div
        ~attrs:[ Style.head ]
        [ Node.div
            ~attrs:[ Style.head_left ]
            [ Node.span ~attrs:[ Style.head_id ] [ Node.text id ] ]
        ; close_button
        ]
    in
    let body =
      match detail with
      | None ->
        [ header_when_loading
        ; Node.div ~attrs:[ Style.loading ] [ Node.text "loading detail…" ]
        ]
      | Some d -> render_detail d
    in
    let prov_section =
      match provenance with
      | None ->
        Node.div
          ~attrs:[ Style.loading ]
          [ Node.text "loading provenance…" ]
      | Some p -> render_provenance p
    in
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
