(** Tier F4 — gallery filter bar.

    Three independent filter dimensions:
    - kind: dropdown populated from the union of currently-listed
      artifacts' kinds (so the operator never sees a value that
      cannot match anything).
    - created_by: same pattern, dropdown of currently-present
      created_by values (excluding the empty string).
    - search: free-text case-insensitive substring match against id,
      kind, created_by, and metadata key names.

    The filter is purely client-side: server returns the full list,
    we project. Reset button clears all three at once. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .bar {
    display: flex;
    flex-wrap: wrap;
    gap: 0.75rem;
    align-items: baseline;
    padding: 0.75rem 1rem;
    background: color-mix(in oklab, var(--color-bg-surface) 70%, transparent);
    border: 1px solid var(--color-border-default);
    border-radius: 6px;
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.78rem;
    color: var(--color-fg-primary);
  }
  .label {
    font-family: 'Cinzel', serif;
    font-size: 0.7rem;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
  }
  .field { display: flex; align-items: baseline; gap: 0.4rem; }
  .select {
    background: var(--color-bg-page);
    color: var(--color-fg-primary);
    border: 1px solid var(--color-border-default);
    border-radius: 3px;
    padding: 3px 6px;
    font-family: inherit;
    font-size: inherit;
  }
  .input {
    background: var(--color-bg-page);
    color: var(--color-fg-primary);
    border: 1px solid var(--color-border-default);
    border-radius: 3px;
    padding: 3px 8px;
    font-family: inherit;
    font-size: inherit;
    min-width: 180px;
  }
  .input:focus { outline: 1px solid var(--accent-blood); }
  .clear {
    margin-left: auto;
    background: transparent;
    color: var(--color-fg-muted);
    border: 1px solid var(--color-border-default);
    border-radius: 3px;
    padding: 3px 10px;
    font-family: inherit;
    font-size: 0.7rem;
    letter-spacing: 0.08em;
    cursor: pointer;
  }
  .clear:hover { color: var(--text-bright); }
  .summary {
    color: var(--color-fg-muted);
    font-style: italic;
    font-family: 'EB Garamond', Georgia, serif;
    font-size: 0.85rem;
  }
|}]

(* ── pure filter logic ────────────────────────────────────────── *)

let lowercase s = String.lowercase s

let case_contains ~haystack ~needle =
  String.is_substring (lowercase haystack) ~substring:(lowercase needle)
;;

let artifact_matches_search (a : Multimodal_types.artifact) ~(query : string)
  : bool
  =
  if String.is_empty query then true
  else
    let q = query in
    case_contains ~haystack:a.id ~needle:q
    || case_contains ~haystack:a.kind ~needle:q
    || case_contains ~haystack:a.created_by ~needle:q
    || List.exists a.metadata_keys ~f:(fun k ->
           case_contains ~haystack:k ~needle:q)
;;

let artifact_passes
    (a : Multimodal_types.artifact)
    ~(kind : string option)
    ~(created_by : string option)
    ~(query : string)
    : bool
  =
  (match kind with
   | None -> true
   | Some k -> String.equal a.kind k)
  && (match created_by with
      | None -> true
      | Some cb -> String.equal a.created_by cb)
  && artifact_matches_search a ~query
;;

let apply_filter
    (artifacts : Multimodal_types.artifact list)
    ~(kind : string option)
    ~(created_by : string option)
    ~(query : string)
    : Multimodal_types.artifact list
  =
  List.filter artifacts ~f:(artifact_passes ~kind ~created_by ~query)
;;

let unique_sorted (xs : string list) : string list =
  List.dedup_and_sort xs ~compare:String.compare
;;

let kinds_of (artifacts : Multimodal_types.artifact list) : string list =
  unique_sorted
    (List.filter_map artifacts ~f:(fun a ->
         if String.is_empty a.kind then None else Some a.kind))
;;

let creators_of (artifacts : Multimodal_types.artifact list) : string list =
  unique_sorted
    (List.filter_map artifacts ~f:(fun a ->
         if String.is_empty a.created_by then None else Some a.created_by))
;;

(* ── view ─────────────────────────────────────────────────────── *)

let on_select_optional
    (var : string option Bonsai.Expert.Var.t)
    : Attr.t
  =
  Attr.on_change (fun _ value ->
      let next = if String.is_empty value then None else Some value in
      Bonsai.Expert.Var.set var next;
      Effect.Ignore)
;;

let render_dropdown
    ~(label : string)
    ~(values : string list)
    ~(current : string option)
    ~(var : string option Bonsai.Expert.Var.t)
    : Node.t
  =
  let any_option =
    Node.option
      ~attrs:
        [ Attr.value ""
        ; (if Option.is_none current then Attr.create "selected" "selected"
           else Attr.empty)
        ]
      [ Node.text "(any)" ]
  in
  let value_options =
    List.map values ~f:(fun v ->
        let is_selected =
          match current with
          | Some c -> String.equal c v
          | None -> false
        in
        Node.option
          ~attrs:
            [ Attr.value v
            ; (if is_selected then Attr.create "selected" "selected"
               else Attr.empty)
            ]
          [ Node.text v ])
  in
  Node.div
    ~attrs:[ Style.field ]
    [ Node.span ~attrs:[ Style.label ] [ Node.text label ]
    ; Node.select
        ~attrs:[ Style.select; on_select_optional var ]
        (any_option :: value_options)
    ]
;;

let render_search ~(current : string) : Node.t =
  Node.div
    ~attrs:[ Style.field ]
    [ Node.span ~attrs:[ Style.label ] [ Node.text "search" ]
    ; Node.input
        ~attrs:
          [ Style.input
          ; Attr.type_ "text"
          ; Attr.placeholder "id / kind / created_by / metadata key"
          ; Attr.value_prop current
          ; Attr.on_input (fun _ value ->
                Bonsai.Expert.Var.set Multimodal_filter_var.search_var value;
                Effect.Ignore)
          ]
        ()
    ]
;;

let render_clear_button : Node.t =
  Node.button
    ~attrs:
      [ Style.clear
      ; Attr.on_click (fun _ ->
            Multimodal_filter_var.clear_all ();
            Effect.Ignore)
      ]
    [ Node.text "reset" ]
;;

let render_summary
    ~(filtered_count : int)
    ~(total : int)
    : Node.t
  =
  let text =
    if filtered_count = total
    then Printf.sprintf "%d artifacts" total
    else Printf.sprintf "%d of %d artifacts" filtered_count total
  in
  Node.span ~attrs:[ Style.summary ] [ Node.text text ]
;;

let view
    ~(artifacts : Multimodal_types.artifact list)
    ~(kind : string option)
    ~(created_by : string option)
    ~(query : string)
    ~(filtered_count : int)
    : Node.t
  =
  let kinds = kinds_of artifacts in
  let creators = creators_of artifacts in
  Node.div
    ~attrs:[ Style.bar ]
    [ render_dropdown
        ~label:"kind" ~values:kinds ~current:kind
        ~var:Multimodal_filter_var.kind_var
    ; render_dropdown
        ~label:"created_by" ~values:creators ~current:created_by
        ~var:Multimodal_filter_var.created_by_var
    ; render_search ~current:query
    ; render_summary ~filtered_count ~total:(List.length artifacts)
    ; render_clear_button
    ]
;;
