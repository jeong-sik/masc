(** Tier F5 — kind-specific payload renderer for the multimodal
    detail panel.

    The renderer dispatches on [detail.kind] (string from server)
    and tries to extract a structured preview from [detail.payload]
    (the raw JSON sub-tree). When extraction fails (missing fields,
    malformed shape), falls back to [detail.payload_pretty] as a
    generic monospace JSON dump.

    Supported preview shapes (best-effort, all optional):

    | kind   | preview when payload has...                   | fallback     |
    |--------|-----------------------------------------------|--------------|
    | image  | "data_url" : "data:image/...,..."             | JSON dump    |
    | image  | "url"      : "https://..."                    | JSON dump    |
    | audio  | "data_url" : "data:audio/...,..."             | JSON dump    |
    | audio  | "url"      : "https://..."                    | JSON dump    |
    | code   | "text"     : "..." (+ optional "language")    | JSON dump    |
    | doc    | "text"     : "..."                            | JSON dump    |
    | (other)| —                                             | JSON dump    |

    Security: image/audio src is taken verbatim from server JSON.
    Operators trust the server output (server is the writer of
    multimodal_artifacts and produces these URLs from
    Multimodal.Workspace_holder). If untrusted external content is
    ever stored, this renderer must add CSP / data-URL allowlist. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .frame {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }
  .image_box {
    background: var(--color-bg-page);
    border: 1px solid var(--color-border-default);
    border-radius: 4px;
    padding: 0.75rem;
    display: flex;
    justify-content: center;
    align-items: center;
    max-height: 400px;
    overflow: auto;
  }
  .image_box img {
    max-width: 100%;
    max-height: 380px;
    object-fit: contain;
  }
  .audio_box {
    background: var(--color-bg-page);
    border: 1px solid var(--color-border-default);
    border-radius: 4px;
    padding: 0.75rem;
  }
  .audio_box audio { width: 100%; }
  .code_pre {
    font-family: 'JetBrains Mono', ui-monospace, Menlo, Consolas, monospace;
    font-size: 0.78rem;
    background: color-mix(in oklab, var(--color-bg-page) 50%, transparent);
    border: 1px solid color-mix(in oklab, var(--color-border-default) 60%, transparent);
    color: var(--color-fg-primary);
    border-radius: 4px;
    padding: 0.75rem;
    margin: 0;
    max-height: 360px;
    overflow: auto;
    white-space: pre;
    word-break: normal;
  }
  .doc_box {
    font-family: 'EB Garamond', Georgia, serif;
    font-size: 0.95rem;
    line-height: 1.5;
    color: var(--color-fg-primary);
    background: color-mix(in oklab, var(--color-bg-page) 35%, transparent);
    border: 1px solid color-mix(in oklab, var(--color-border-default) 50%, transparent);
    border-radius: 4px;
    padding: 1rem 1.25rem;
    max-height: 360px;
    overflow: auto;
    white-space: pre-wrap;
  }
  .lang_tag {
    font-family: 'JetBrains Mono', ui-monospace, monospace;
    font-size: 0.7rem;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    align-self: flex-start;
    padding: 2px 8px;
    border: 1px solid var(--color-border-default);
    border-radius: 3px;
  }
  .json_pre {
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
|}]

(* ── extract helpers ──────────────────────────────────────────── *)

let string_member (json : Yojson.Safe.t) (name : string) : string option =
  match Yojson.Safe.Util.member name json with
  | `String s when not (String.is_empty s) -> Some s
  | _ -> None
;;

(** Try [data_url] first (inline base64 data URI), fall back to [url]
    for externally-hosted resources. *)
let extract_src (payload : Yojson.Safe.t) : string option =
  match string_member payload "data_url" with
  | Some _ as s -> s
  | None -> string_member payload "url"
;;

(* ── primitive renderers ──────────────────────────────────────── *)

let json_fallback (payload_pretty : string) : Node.t =
  Node.pre ~attrs:[ Style.json_pre ] [ Node.text payload_pretty ]
;;

let render_image ~payload ~payload_pretty : Node.t =
  match extract_src payload with
  | None -> json_fallback payload_pretty
  | Some src ->
    Node.div
      ~attrs:[ Style.image_box ]
      [ Node.img
          ~attrs:
            [ Attr.src src
            ; Attr.create "alt" "multimodal artifact preview"
            ; Attr.create "loading" "lazy"
            ]
          ()
      ]
;;

let render_audio ~payload ~payload_pretty : Node.t =
  match extract_src payload with
  | None -> json_fallback payload_pretty
  | Some src ->
    Node.div
      ~attrs:[ Style.audio_box ]
      [ Node.create "audio"
          ~attrs:
            [ Attr.create "controls" "controls"
            ; Attr.create "preload" "metadata"
            ; Attr.src src
            ]
          [ Node.text "Your browser does not support inline audio." ]
      ]
;;

let render_code ~payload ~payload_pretty : Node.t list =
  match string_member payload "text" with
  | None -> [ json_fallback payload_pretty ]
  | Some text ->
    let lang_tag_node =
      match string_member payload "language" with
      | None -> Node.none
      | Some lang ->
        Node.span ~attrs:[ Style.lang_tag ] [ Node.text lang ]
    in
    [ lang_tag_node
    ; Node.pre ~attrs:[ Style.code_pre ] [ Node.text text ]
    ]
;;

let render_doc ~payload ~payload_pretty : Node.t =
  match string_member payload "text" with
  | None -> json_fallback payload_pretty
  | Some text -> Node.div ~attrs:[ Style.doc_box ] [ Node.text text ]
;;

(* ── public dispatch ──────────────────────────────────────────── *)

(** Render the kind-specific preview for a detail. Returns a list of
    nodes (the code renderer needs two — language tag + pre block —
    so the result type is [list], not [Node.t]). *)
let render
    ~(kind : string)
    ~(payload : Yojson.Safe.t)
    ~(payload_pretty : string)
    : Node.t list
  =
  let frame children =
    [ Node.div ~attrs:[ Style.frame ] children ]
  in
  match kind with
  | "image" -> frame [ render_image ~payload ~payload_pretty ]
  | "audio" -> frame [ render_audio ~payload ~payload_pretty ]
  | "code" -> frame (render_code ~payload ~payload_pretty)
  | "doc" -> frame [ render_doc ~payload ~payload_pretty ]
  | _ -> [ json_fallback payload_pretty ]
;;
