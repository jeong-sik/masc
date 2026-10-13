(** The wiki lint rules over a {!Wiki_graph.t}. Pure and deterministic: the
    same graph gives the same findings in the same order.

    First step of RFC-wiki-lint-and-page-contracts (§4.2, §4.3): broken
    links, links in a shape the lint does not interpret, orphan pages, pages
    without sources, pages whose only sources are hearsay, and pages whose
    header does not read. Log and revision checks, unreachable pages and
    contradictions are later steps. *)

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

val kind : finding -> string
(** The wire name: ["broken_link"], ["unsupported_link"], ["orphan"],
    ["orphan_unconfirmed"], ["missing_sources"], ["hearsay_only"],
    ["unreadable_page"]. *)

val all_kinds : string list
(** Every {!kind}, in the order a report lists them. *)

val subject : finding -> string
(** The page (or file) the finding is about. *)

val run : Wiki_graph.t -> finding list
(** Every finding, sorted by subject, then line, then kind. *)

val counts : finding list -> (string * int) list
(** One entry per {!all_kinds}, zero included, in that order. *)
