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

type mosaic_refusal =
  | Fetch_failed of { detail : string }
      (** curl delivered no body: an HTTP error status, a timeout, no host. *)
  | Empty_body  (** The image URL answered with zero bytes. *)
  | Cache_unreadable of { detail : string }
      (** The downloaded file could not be read back. *)
  | Decode_failed of { detail : string }
      (** The body reached the decoder and no frame came out. *)

type mosaic_entry =
  | Mosaic of string list
      (** Rendered half-block mosaic lines for the image URL. *)
  | Refused of mosaic_refusal
      (** Why there is no mosaic. Recorded so the background fetch does not
          download and decode the same URL again on every preview parse, and
          said on the card so a missing picture is not mistaken for a page
          with no og:image. *)

val mosaic_refusal_text : mosaic_refusal -> string
(** The refusal as one line for the card. *)

val mosaic_lookup : string -> mosaic_entry option
(** What the background fetch decided about an image URL, or [None] while it
    has not decided yet. Refusals remain visible until an explicit retry;
    no refusal is evidence of permanent failure. *)

val load_mosaic : compute:(unit -> mosaic_entry) -> string -> unit
(** Atomically reserve an undecided URL, then compute and store its outcome.
    Existing decisions and pending work are left alone. The synchronous
    callback runs outside the cache lock; exceptions release the reservation
    and propagate. Keep blocking work and this call in the same worker. *)

val retry_mosaic : retry:(unit -> mosaic_entry) -> string -> unit
(** Atomically reserve a refused or undecided URL for one explicit retry. A
    rendered mosaic and pending work are left alone: the first has nothing to
    retry, the second would get two writers. Undecided is claimed because a
    direct image link never has a mosaic -- no page is fetched for one -- and
    the retry is what drops the body its first view cached. The synchronous
    callback refreshes input and returns its outcome; exceptions restore what
    was there and propagate. Clearing the cache during either callback discards
    its eventual outcome but retains the reservation until it exits, preventing
    overlapping work. *)

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
