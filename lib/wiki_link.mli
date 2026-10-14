(** Links in a wiki page body. Pure: the page text goes in, a list of links
    comes out, and nothing is read or written.

    The parser is total. It never raises and never drops a link shape it does
    not know; it names the shape and leaves it to the lint rules to decide
    whether that is an error (RFC-wiki-lint-and-page-contracts §5). Text
    inside a fenced code block, inside an inline code span, and an image
    [![alt](target)] are not links and are skipped. *)

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
(** The links of a page body, in reading order. *)
