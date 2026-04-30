(** Tier F1 — Multimodal artifact gallery.

    Reads [Multimodal_var] (populated by [Multimodal_fetch]) and
    renders one card per artifact: id (truncated), kind badge,
    metadata key summary, created_by.

    Empty state ("waiting for tagged tool output") is the common case
    until [MASC_MULTIMODAL=1] + [MASC_TOOL_EMISSION=1] are both on
    AND a keeper tool emits a tagged JSON result.

    The view is read-only — interactions (filtering, opening payload)
    are deferred to F2. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .root {
    min-height: 100vh;
    background: var(--color-bg-page);
    color: var(--color-fg-primary);
    font-family: 'EB Garamond', 'Noto Sans KR', Georgia, serif;
    padding: 3rem 4rem;
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
  }
  .header { display: flex; align-items: baseline; gap: 1rem; }
  .title {
    font-family: 'Cinzel', serif;
    font-weight: 500;
    font-size: 1.75rem;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    color: var(--text-bright);
    margin: 0;
  }
  .count {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-variant-numeric: tabular-nums;
    font-size: 0.85rem;
    color: var(--color-fg-muted);
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 1rem;
  }
  .card {
    background: var(--color-bg-surface);
    border: 1px solid var(--color-border-default);
    border-radius: 6px;
    padding: 1rem;
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .card_head {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .badge {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.7rem;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    padding: 2px 8px;
    border-radius: 3px;
    background: color-mix(in oklab, var(--accent-blood) 20%, transparent);
    color: var(--text-bright);
    border: 1px solid color-mix(in oklab, var(--accent-blood) 40%, transparent);
  }
  .id {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.75rem;
    color: var(--color-fg-muted);
  }
  .meta_keys {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.7rem;
    color: var(--color-fg-primary);
    word-break: break-all;
  }
  .created_by {
    font-family: 'EB Garamond', Georgia, serif;
    font-size: 0.85rem;
    font-style: italic;
    color: var(--color-fg-muted);
  }
  .empty {
    padding: 2rem;
    text-align: center;
    color: var(--color-fg-muted);
    border: 1px dashed var(--color-border-default);
    border-radius: 6px;
  }
|}]

let truncate_id (s : string) : string =
  if String.length s <= 8 then s
  else String.sub s ~pos:0 ~len:8 ^ "…"
;;

let card (a : Multimodal_types.artifact) : Node.t =
  Node.div
    ~attrs:[ Style.card ]
    [ Node.div
        ~attrs:[ Style.card_head ]
        [ Node.span ~attrs:[ Style.badge ] [ Node.text a.kind ]
        ; Node.span ~attrs:[ Style.id ] [ Node.text (truncate_id a.id) ]
        ]
    ; Node.div
        ~attrs:[ Style.meta_keys ]
        [ Node.text
            (match a.metadata_keys with
             | [] -> "(no metadata)"
             | keys -> "metadata: " ^ String.concat ~sep:", " keys)
        ]
    ; (if String.is_empty a.created_by then Node.none
       else
         Node.div
           ~attrs:[ Style.created_by ]
           [ Node.text ("created by " ^ a.created_by) ])
    ]
;;

let empty_state : Node.t =
  Node.div
    ~attrs:[ Style.empty ]
    [ Node.text
        "waiting for tagged tool output. enable \
         MASC_TOOL_EMISSION=1 + MASC_MULTIMODAL=1 and have a \
         keeper tool emit JSON with __multimodal_kind / \
         __multimodal_id keys."
    ]
;;

let view_of_response (r : Multimodal_types.response) : Node.t =
  Node.div
    ~attrs:[ Style.root; Attr.role "main"; Attr.create "aria-label" "Multimodal gallery" ]
    [ Node.div
        ~attrs:[ Style.header ]
        [ Node.h1 ~attrs:[ Style.title ] [ Node.text "Multimodal · gallery" ]
        ; Node.span
            ~attrs:[ Style.count ]
            [ Node.text (Printf.sprintf "%d artifacts" r.count) ]
        ]
    ; (if List.is_empty r.artifacts then empty_state
       else
         Node.div
           ~attrs:[ Style.grid ]
           (List.map r.artifacts ~f:card))
    ]
;;

let component (_graph @ local) =
  Bonsai.map (Bonsai.Expert.Var.value Multimodal_var.var) ~f:view_of_response
;;
