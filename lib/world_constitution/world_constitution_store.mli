(** Article ledger for one world (RFC-0442).

    The ledger is an append-only JSONL file under
    [<base_path>/.masc/constitution/]. Each line is one move — a norm written
    down, or one taken back — and the norms a world currently holds are those
    lines folded in order. Article counts are bounded by the byte ceiling the
    prompt slot puts on them, so reading the whole file is the read path; there
    is no derived snapshot to keep in step.

    A world with no ledger has no articles. That is the fresh-state contract,
    not an error: nothing here reads a legacy layout or converts one. *)

val ledger_path : base_path:string -> string
(** [<base_path>/.masc/constitution/articles.jsonl]. The file need not
    exist. *)

type append_error =
  | Directory_unavailable of {
      path : string;
      detail : string;
    }
  | Ledger_moved of {
      expected : int;
      actual : int;
    }
      (** Someone appended between the caller's read and its write. The caller
          decided something from what it read — the byte ceiling is decided
          exactly this way — so the write is refused rather than applied to a
          ledger the caller never saw. *)
  | Write_failed of {
      path : string;
      detail : string;
    }

val append_error_to_string : append_error -> string

val append_at :
  base_path:string ->
  expected_end_offset:int ->
  World_constitution_types.entry ->
  (unit, append_error) result
(** Record one move, provided the ledger's complete lines still end where
    the caller's {!load} left them. An unterminated last line after that
    point is cut before the move is written. Whether the world agreed is settled on the board before
    anyone calls this; the ledger writes what it is told and judges nothing.

    The offset is what makes a read-then-decide safe. Two keepers that both
    read a world one article below the ceiling would both pass their own check
    and both append, leaving the rendered articles over a ceiling nothing
    re-checks on the way out. Here the second one is told its read is
    stale. *)

(** Whether a newline follows the line. Every append writes one, so the one
    line that can lack it is the last line of the file: an append that stopped
    before its newline, or a hand edit. That line is not a move, whatever its
    bytes read as: it is reported in [rejected], folds into nothing, and the
    next {!append_at} cuts it. *)
type line_end =
  | Newline_terminated
  | Unterminated_final_line

val line_end_to_string : line_end -> string

type rejected_line = {
  line_number : int;  (** 1-based, counting every line including blanks. *)
  line_end : line_end;
  detail : string;
}

type isolated_line = {
  line_number : int;  (** 1-based, counting every line including blanks. *)
  subject : string;
      (** The first name the roster did not resolve: [Added.author],
          [Removed.by], or [Replaced.by] followed by its [article.author]. *)
  article_ids : World_constitution_types.Article_id.t list;
      (** The ids withheld by this unresolved move: the added or removed id,
          or the replacement's id and every superseded id. This does not
          admit the move or prove a retirement; it prevents an earlier norm
          becoming current merely because the later move was isolated. A
          later resolved write may adopt an id again. *)
}

type ledger = {
  end_offset : int;
      (** Where the ledger's complete lines ended when this was read: the byte
          after the last newline. An unterminated last line lies past it. Pass
          it to {!append_at} so a write built on this read cannot land on a
          different ledger. *)
  articles : World_constitution_types.t list;
      (** The norms the world currently holds, in the order they were first
          written. An article written, removed and written again returns at the
          end, because that is when the world decided to keep it. A line whose
          subject [resolve_subject] refused admits no norm and withholds the
          ids it affects. Neither its new text nor the earlier text it
          disputed is the world's to render without resolving that move
          (RFC-0504 §2.4). *)
  entries : World_constitution_types.entry list;
      (** Every decoded move, in ledger order. Removed entries retain who,
          when and why; the preceding Added entry retains the removed text.
          History is evidence, not an active norm for the prompt. Isolated
          lines stay here — what the file says happened is kept — while
          {!isolated} names them for the reader. *)
  rejected : rejected_line list;
      (** Lines that did not decode, in file order. They stay in the file: a
          reader reports them rather than dropping them silently, because a
          line nobody can read is a norm somebody wrote. *)
  isolated : isolated_line list;
      (** Lines that decoded but whose subject [resolve_subject] refused, in
          file order. They stay in the file and in [entries]; a reader
          reports them beside [rejected], because a norm that stopped
          rendering must not vanish quietly (RFC-0504 §2.4). *)
}

type read_error =
  | Unreadable of {
      path : string;
      detail : string;
    }

val read_error_to_string : read_error -> string

val load :
  base_path:string ->
  resolve_subject:(string -> bool) ->
  (ledger, read_error) result
(** Read the whole ledger and fold it, keeping every decoded move. History
    readers and writers use this; the per-turn prompt build uses
    {!load_articles} instead. A missing file is an empty ledger.

    [resolve_subject] names the roster: a decoded line whose subject it
    refuses is not admitted, and the article ids it affects are withheld
    from [articles]. The line and its ids land in [isolated] instead
    (RFC-0504 §2.4); skipping the line must not revive the earlier version
    of a withdrawn or edited norm. Production callers pass their world's keeper
    registry; a test that owns no roster passes one that holds every
    subject it wrote. *)

val load_articles :
  base_path:string ->
  resolve_subject:(string -> bool) ->
  (World_constitution_types.t list, read_error) result
(** Read the ledger and fold it, keeping only the norms the world currently
    holds. The decoded history grows without bound while the held articles
    stay small, so an ordinary load must not build it: the per-turn prompt
    build renders articles and would otherwise retain every past article and
    removal reason on every turn. A missing file is no articles.
    [resolve_subject] withholds affected ids exactly as {!load} does; this read
    keeps no isolated-line report, so a roster change that newly isolates a
    line surfaces through the tool read, not here. *)

(** Which ledger bytes a read folded: the length and SHA-256 of its complete
    lines. An unterminated last line is in neither. *)
type position = {
  end_offset : int;
  digest : string;
}

type projection_status =
  | Resolved
  | Isolated_history
      (** An isolated move exists in the folded history. A native System of
          unknown provenance may still contain an earlier version even when
          every affected id was explicitly readopted. This status does not
          grow with inactive history. *)

type held_projection = private {
  articles : World_constitution_types.t list;
  at : position;
  status : projection_status;
      (** Whether historical isolation makes a previous System's article
          projection uncertain. Readopted articles are active in [articles]
          and are included in the complete current snapshot. *)
}

val load_held :
  base_path:string ->
  resolve_subject:(string -> bool) ->
  (held_projection, read_error) result
(** {!load_articles}, its projection status and the position of the bytes it folded.
    Withholding describes the current projection, not an approved removal.
    The same
    [resolve_subject] must fold both this read and the later
    {!load_articles_at} at its position, or the basis and the turn disagree
    about what the world holds. *)

val load_articles_at :
  base_path:string ->
  resolve_subject:(string -> bool) ->
  position ->
  (World_constitution_types.t list option, read_error) result
(** The articles the world held when the ledger ended at [position]. The
    ledger only grows, so those are the fold of its first [end_offset] bytes
    now; [None] when those bytes no longer hash to [position]'s digest, or the
    ledger is shorter. Folds without the history, as {!load_articles} does. *)
