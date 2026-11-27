(** Links and typed rich embeds in a wiki page body. Pure: the page text goes
    in, lists of links or embeds come out, and nothing is read or written.

    Both parsers are total. They never raise and never drop a shape they do
    not know; they name the shape as a closed sum variant and leave it to the
    lint rules to decide whether that is an error. Text inside a fenced code
    block and inside an inline code span is skipped by both parsers. *)

type target =
  | Page of string
      (** [\[text\](name.md)] where [name] passes
          {!Wiki_page_name.validate_page_name}. The page may or may not
          exist; that is the graph's question. *)
  | Own_file of string
      (** [index.md] or [log.md]: the wiki's own files, not pages. *)
  | External of string  (** [http://…] or [https://…]. Never checked. *)
  | Invalid_name of string
      (** [\[text\](Foo.md)]: a Markdown file name in the page directory that
          breaks the page name rule. The tool refuses such a name rather than
          repairing it, so the lint treats the link as one whose target
          cannot exist. *)
  | Unsupported of string
      (** A shape the first step does not interpret. The string names the
          shape: ["anchor"], ["path"], ["wikilink"], ["scheme"],
          ["not_markdown"]. *)

type link =
  { text : string  (** The label, or the name inside [\[\[…\]\]]. *)
  ; target : target
  ; raw : string  (** The target as written, without any trailing title. *)
  ; line : int  (** 1-based line in the text given to {!extract}. *)
  }

val classify : string -> target
(** The shape of one link target as written. *)

val extract : string -> link list
(** The links of a page body, in reading order. Images ([![alt](target)]) and
    Obsidian embeds ([![[…]]]) are skipped here and extracted by
    {!extract_embeds}. *)

(** {1 Typed embeds} *)

type embed_syntax =
  | Obsidian_embed
      (** [![[media:<sha256>]]], [![[wiki:<slug>]]], bare [![[<slug>]]], or
          [![[artifact:<id>]]] (with optional [|label]). *)
  | Markdown_media
      (** Standard Markdown image targeting the workspace media route:
          [![alt](/api/v1/media/<sha256>)]. *)

type embed_kind =
  | Embed_media
  | Embed_wiki
  | Embed_artifact

type embed_target =
  | Media_embed of string
      (** Valid 64-char lowercase hexadecimal SHA-256 workspace media token. *)
  | Wiki_embed of string
      (** Valid wiki page slug passing {!Wiki_page_name.validate_page_name}. *)
  | Artifact_embed of string
      (** Valid published artifact id passing {!Published_artifact.valid_id}. *)
  | Invalid_embed of
      { kind : embed_kind
      ; raw : string
      }
      (** Recognized embed syntax whose target fails its identifier rule. *)
  | Unsupported_embed of
      { scheme : string
      ; raw : string
      }
      (** [![[<scheme>:<raw>]]] with an unknown scheme; never coerced to a
          wiki slug. *)

type embed =
  { target : embed_target
  ; label : string option
      (** Optional caption/label after [|] in Obsidian syntax, or trimmed alt
          text in Markdown media syntax. *)
  ; syntax : embed_syntax
  ; raw : string
      (** The full [![[…]]] token for Obsidian syntax, or the URL target as
          written for Markdown media syntax. *)
  ; line : int  (** 1-based line in the text given to {!extract_embeds}. *)
  }

val embed_kind_to_string : embed_kind -> string
(** Wire name: ["media"], ["wiki"], or ["artifact"]. *)

val embed_syntax_to_string : embed_syntax -> string
(** Wire name: ["obsidian"] or ["markdown_media"]. *)

val is_valid_media_token : string -> bool
(** [true] iff the string is a 64-character lowercase hex SHA-256 digest. *)

val classify_obsidian_embed : string -> embed_target
(** Classify the target part (before any [|label]) of an [![[…]]] embed. *)

val extract_embeds : string -> embed list
(** All typed embeds of a page body, in reading order. Non-media Markdown
    images ([![alt](https://…)], [![alt](pic.png)]) are ignored. *)

val media_refs_of_embeds : embed list -> string list
(** Sorted, deduplicated workspace media SHA-256 digests referenced by
    {!Media_embed} entries. *)
