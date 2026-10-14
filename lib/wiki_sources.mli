(** The [## Sources] section of a page body. Pure.

    One reference per line, each starting with [- ] and one of the prefixes
    [repo:], [board:], [artifact:], [url:], [said:]
    (RFC-wiki-lint-and-page-contracts §8). Whether the thing after the prefix
    exists is not checked: that needs the repository or the Board, and the
    lint reads nothing but the wiki. [said:] is hearsay: there is nothing to
    read again, so it does not count as a source. *)

type t =
  { references : int  (** Lines with [repo:], [board:], [artifact:] or [url:]. *)
  ; hearsay : int  (** Lines with [said:]. *)
  }

val of_body : string -> t
(** Counts the reference lines under the first [## Sources] heading, up to
    the next heading. A page without that heading has none. Lines inside a
    fenced code block are not counted. *)
