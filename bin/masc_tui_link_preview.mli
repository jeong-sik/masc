(** Masc_tui_link_preview — Web link previews, OpenGraph extraction,
    rich embed cards, and 3D drop-shadow inspection modal. *)

type link_kind =
  | Github of {
      owner : string;
      repo : string;
      item : string;
    }
  | Arxiv of { id : string }
  | HackerNews of { item_id : string }
  | YouTube of { video_id : string }
  | Image_direct of { ext : string }
  | Web_page

type og_preview = {
  url : string;
  canonical_url : string option;
  title : string option;
  description : string option;
  site_name : string option;
  image_url : string option;
  favicon_url : string option;
  kind : link_kind;
  cache_state : string;
}

val synthesize_preview : string -> og_preview
(** Synthesizes semantic OpenGraph metadata from the URL structure without network calls. *)

val of_json : string -> Yojson.Safe.t -> og_preview option
(** Decodes an OpenGraph preview JSON envelope (such as returned by the dashboard API). *)

val to_json : og_preview -> Yojson.Safe.t

val cache_lookup : string -> og_preview option
val cache_store : og_preview -> unit
val get_preview : string -> og_preview
val clear_cache : unit -> unit

val site_icon : og_preview -> string
(** Returns a decorative glyph for the site (e.g. 🐙, 📄, 🟧, ▶️, 🖼️, 🌐). *)

val site_label : og_preview -> string
(** Returns human-readable site name or domain. *)

val render_compact_badge : og_preview -> string
(** One-line compact badge for the link. *)

val render_inline_card : width:int -> og_preview -> string list
(** Multi-line styled Unicode box embed card for chat stream rendering. *)

val render_modal_card : width:int -> height:int -> og_preview -> string list
(** Full-width rich embed layout for the 3D drop-shadow preview modal. *)
