(** The lint report as the tool returns it. Pure: findings and a request go
    in, JSON text comes out (RFC-wiki-lint-and-page-contracts §4.1, §4.2).

    The report is capped so a tool result stays under the wire limit that
    would turn it into a sealed blob. Counts always describe every finding;
    [findings] is one page of them, and [next_cursor] reads the next. *)

type request =
  { page : string option  (** Only findings about this page. *)
  ; kind : string option  (** Only findings of this {!Wiki_lint.kind}. *)
  ; limit : int option  (** At most this many findings in one page. *)
  ; cursor : string option  (** [next_cursor] of the previous response. *)
  }

type problem =
  | Unknown_kind of string
  | Bad_limit
  | Bad_cursor of string
  | Stale_cursor
      (** The cursor was issued for a different list of findings: the wiki
          changed between the calls, or [kind]/[page] differ from the call that
          issued it. *)


val problem_to_string : problem -> string

val default_limit : int
val max_limit : int

val byte_budget : int
(** The most finding bytes one response carries. A page always holds at least
    one finding, so a single long finding can exceed it. *)

val render
  :  pages_total:int
  -> pages_unreadable:int
  -> log:Wiki_log.t
  -> findings:Wiki_lint.finding list
  -> request
  -> (Yojson.Safe.t, problem) result
(** [findings] is the full, sorted output of {!Wiki_lint.run}. [log] is the
    same {!Wiki_log} read; only its two counts are reported. *)
