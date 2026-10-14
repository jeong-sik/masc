(** The wiki lint rules over a {!Wiki_graph.t}. Pure and deterministic: the
    same graph gives the same findings in the same order.

    First step of RFC-wiki-lint-and-page-contracts (§4.2, §4.3): broken
    links, links in a shape the lint does not interpret, orphan pages, pages
    without sources, pages whose only sources are hearsay, pages whose
    header does not read. The second step (§4.5, §7) adds the page the log
    has run ahead of. Unreachable pages and contradictions are later steps. *)

type finding =
  | Broken_link of
      { page : string
      ; line : int
      ; target : string  (** As written in the page. *)
      }
  | Unsupported_link of
      { page : string
      ; line : int
      ; form : string  (** The shape: ["anchor"], ["path"], ["wikilink"], … *)
      ; target : string
      }
  | Orphan of { page : string }
  | Orphan_unconfirmed of { page : string }
      (** No readable page links here, but some page does not read, so a link
          there could still point at this page. *)
  | Missing_sources of { page : string }
  | Hearsay_only of { page : string }
  | Unreadable_page of
      { file : string
      ; reason : string
      }
  | Revision_log_gap of
      { page : string
      ; log_revision : int  (** The highest [r<N>] the log records here. *)
      ; page_revision : int  (** The revision the page file carries. *)
      }
      (** The log records a revision this page never reached. The other
          direction -- a page ahead of the log -- is not a finding: a read
          takes no lock, so it sees the page of a write in flight before the
          log line of that write (§4.5). *)
  | Revision_log_hole of
      { page : string
      ; missing : int  (** The lowest [r<N>] the log skips below its highest. *)
      }
      (** The log skips a revision below the highest one it records for this
          page. A page's lines are [r1], [r2], ... with no skips, so the missing
          value is a line that reached the page and never reached the log --
          what an [append_log] that failed leaves. A write in flight only
          leaves the top of the column empty, so this is not that.

          Refused rather than guessed in two cases: no hole is reported at all
          when the log has any dropped line ([Wiki_log.t.unknown_action] or
          [Wiki_log.t.unreadable_line] above zero), because such a line may
          have carried a revision where it cannot be read; and the column is
          taken to start at the lowest revision the log records for the page,
          not at [r1], so a page with no create line is not reported forever. *)

val kind : finding -> string
(** The wire name: ["broken_link"], ["unsupported_link"], ["orphan"],
    ["orphan_unconfirmed"], ["missing_sources"], ["hearsay_only"],
    ["unreadable_page"], ["revision_log_gap"], ["revision_log_hole"]. *)

val all_kinds : string list
(** Every {!kind}, in the order a report lists them. *)

val subject : finding -> string
(** The page (or file) the finding is about. *)

val run : Wiki_graph.t -> log:Wiki_log.t -> finding list
(** Every finding, sorted by subject, then line, then kind. The log is the
    one {!Wiki_log} read of the same directory; {!Wiki_log.empty} is what a
    wiki with no [log.md] gives. *)

val log_hole_suppressed : Wiki_log.t -> bool
(** [true] when the log has a line the parser dropped ([unknown_action] or
    [unreadable_line] above zero), the one condition under which
    {!Revision_log_hole} is not reported at all. A dropped line may have
    carried an [r<N>] the check cannot read, so the hole rule refuses to guess.
    The report surfaces this flag so "no holes" and "check off" are not the
    same answer; [log.md] is append-only, so once a dropped line is in it the
    check stays off until the file is fixed by hand. *)

val counts : finding list -> (string * int) list
(** One entry per {!all_kinds}, zero included, in that order. *)
