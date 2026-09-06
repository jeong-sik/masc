(** Masc_tui_link_preview — Web link previews, OpenGraph extraction,
    rich embed cards, and 3D drop-shadow inspection modal. *)

type link_kind =
  | Github of {
      label : string;
      owner : string;
      repo : string;
    }
  | Arxiv of { id : string }
  | HackerNews of { item_id : string }
  | YouTube of { video_id : string }
  | Image_direct of { ext : string }
  | Web_page

type og_preview = {
  url : string;
  title : string option;
  description : string option;
  site_name : string option;
  image_url : string option;
  kind : link_kind;
  has_metadata : bool;
}

val synthesize_preview : string -> og_preview
(** Synthesizes semantic OpenGraph metadata from the URL structure without network calls.
    Delegates to [Masc_tui_link_label.label] for GitHub and known resource shapes. *)

val has_informative_preview : og_preview -> bool
(** Whether this preview carries informative structural metadata beyond a bare host.
    Respects the silence contract: returns [false] for arbitrary web links where
    nothing meaningful can be inferred from the URL alone. *)

val cache_lookup : string -> og_preview option
val cache_store : og_preview -> unit
val get_preview : string -> og_preview
val clear_cache : unit -> unit

val parse_og_html : url:string -> body:string -> og_preview
(** Merge a fetched page's <title> and og:* meta tags onto the URL-synthesized
    base, keeping its [kind]. Returns the synthesized base unchanged when the
    page carried no title or og:* metadata, so [has_metadata] never claims
    fetched data that is absent. Pure: no network, unit-testable. *)

val set_background_fetch : (string -> unit) -> unit
(** Register the background fetcher the TUI injects at startup. [get_preview]
    calls it once per URL on the first cache miss; the fetcher is expected to
    fetch the page, replace the synthesized cache entry via {!cache_store}, and
    request a redraw. A no-op until registered (keeps [get_preview] pure). *)

val site_icon : og_preview -> string
(** Decorative glyph for the site (e.g. 🐙, 📄, 🟧, ▶️, 🖼️, 🌐). *)

val site_label : og_preview -> string
(** Human-readable site name or domain. *)

val render_compact_badge : og_preview -> string option
(** One-line compact badge for the link (e.g. "╰─ 🐙 [GitHub] masc PR #30866").
    Returns [None] for links that carry no informative metadata (silence contract). *)

val render_notion_card : width:int -> og_preview -> string list
(** Notion-grade 2-column web bookmark block with platform branding and TrueColor visual banner.
    On narrow viewports (width < 55), gracefully degrades to a 1-column layout. *)

val render_inline_card : width:int -> og_preview -> string list
(** Multi-line styled Unicode box embed card for chat stream rendering.
    Uses grapheme-safe cell width measurement and Notion-style 2-column layout. *)

val render_modal_card : width:int -> height:int -> og_preview -> string list
(** Full-width rich embed layout for the 3D drop-shadow preview modal. *)
