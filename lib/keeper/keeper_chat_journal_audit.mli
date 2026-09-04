(** RFC-0412 stage 2 consistency auditor: proves the stage-1 journal
    ({!Keeper_chat_event_log}) and the legacy {!Keeper_chat_store} record the
    same turns, before any read path switches to the journal. Pure comparison
    core + IO shell; the sweep is driven from the server maintenance fiber.

    The comparison encodes the known dual-write skews explicitly rather than
    discovering them: surface-post mid-turn rows carry no join keys and are an
    exclusion class, never a mismatch; a crashed turn leaves a truncated
    journal (no terminal event), which is its own verdict. *)

type mismatch_kind =
  | Terminal_outcome
      (** The journal ended [Run_finished] but the joined terminal row's
          [stream_lifecycle] ends [Run_error] (or its kind is
          [Transport_failure]), or vice versa. *)
  | Assistant_text
      (** The terminal assistant row's content differs from the journal's
          [Reply_details.reply] (both sides are the post-redaction view), or
          the journal carries a non-empty reply that no store row persists. *)
  | Tool_rows
      (** A [Tool_result_ready] [execution_id] has no joined tool row, or a
          joined tool row has no [Tool_result_ready]. *)
  | Seq_gap
      (** Journal seqs are not contiguous [0..n-1]: a swallowed hook exception
          consumed a seq without writing a line. *)
  | Missing_terminal_row
      (** Terminal events are present in the journal but no store rows join
          the operation at all. *)
[@@deriving show, eq]

type verdict =
  | Match
  | Mismatch of mismatch_kind list
  | Journal_missing
      (** Fail-open append may never have created the file. *)
  | Journal_truncated
      (** No terminal event: the turn crashed or was interrupted. *)
  | Journal_corrupt of string
      (** {!Keeper_chat_event_log.read_journal} raised [Invalid_argument], or
          the sweep hit an unexpected per-file failure. *)
  | Store_unreadable of string
      (** The journal carries terminal events but
          {!Keeper_chat_store.load_all} yielded zero rows while [Unix.stat]
          shows a non-empty store file: [load_all] converts read failures
          (and all-lines-unparseable reads) into [[]], so the stat-size
          heuristic is the only signal that separates a store read failure
          from a genuinely empty store. *)
[@@deriving show, eq]

(** Bounded constructor name of a verdict, for metric labels:
    ["match" | "mismatch" | "journal_missing" | "journal_truncated" |
    "journal_corrupt" | "store_unreadable"]. {!show_verdict} embeds exception
    strings (paths, [Unix_error]s) and must stay out of metric labels — it
    belongs in the log line. *)
val verdict_label : verdict -> string

(** The exclusion class: assistant rows written mid-turn by the surface-post
    tool carry neither [turn_ref] nor delivery provenance
    (keeper_tool_in_process_runtime.ml). They are identifiable only by landing
    inside the turn's [first_ts..last_ts] journal window, and are never a
    mismatch. *)
val is_surface_post_row :
  first_ts:float -> last_ts:float -> Keeper_chat_store.chat_message -> bool

(** Pure: compare one operation's journaled events against the store rows
    already joined to that operation (delivery-key / [turn_ref] join performed
    by the caller via {!Keeper_chat_store.transcript_of_messages} and the
    operation delivery key). Rows without join keys are dropped from
    consideration when {!is_surface_post_row} accepts them; every other row
    passed in is treated as joined. *)
val compare :
  Keeper_chat_event_log.journaled_event list ->
  Keeper_chat_store.chat_message list ->
  verdict

(** Shared core of the IO shell: journal entries already read, store rows
    already loaded. Joins the rows by [turn_ref] and by the [Operation]
    delivery key derived from [operation_id] (via
    {!Keeper_chat_store.transcript_of_messages}) and compares. {!sweep} calls
    this per journal file against a row list loaded once per keeper. *)
val audit_entries :
  operation_id:string ->
  entries:Keeper_chat_event_log.journaled_event list ->
  rows:Keeper_chat_store.chat_message list ->
  verdict

(** IO shell: audit one operation. Reads the journal ([Journal_missing] /
    [Journal_corrupt] come from here) via
    {!Keeper_chat_event_log.journal_path} +
    {!Keeper_chat_event_log.read_journal_path} — never
    {!Keeper_chat_event_log.open_journal}, whose mkdir would mint junk
    directories for a non-canonical [operation_id] whose sanitized path does
    not exist — [Keeper_chat_store.load_all]s the store, and compares. A
    non-empty store file that loads zero rows against a terminal-event journal
    is [Store_unreadable], not [Missing_terminal_row]. *)
val audit_operation :
  base_dir:string -> keeper_name:string -> operation_id:string -> verdict

(** Sweep every journal file under [<base>/.masc/keeper_chat_events/], audit
    each, and return [(keeper, operation_id, verdict)] triples. One
    {!Keeper_chat_store.load_all} per keeper per pass, shared across that
    keeper's journal files.

    Only files whose mtime age satisfies [grace_sec <= age <= window_sec] are
    audited (default [grace_sec] is 600s): journals younger than the grace
    bound may still be appended by a live turn — live turns are never
    half-read — while crashed turns are caught once cold, inside the window.
    Journals whose filename stem is not canonical
    ({!Workspace_utils_backend_setup.sanitize_namespace_segment} is not
    idempotent for e.g. uppercase stems, so the stem cannot round-trip through
    {!Keeper_chat_event_log.journal_path}) are outside the audit and skipped,
    as are journals that vanish between readdir and read.

    Never raises except [Eio.Cancel.Cancelled]: per-file failures become
    [Journal_corrupt] verdicts. *)
val sweep :
  base_dir:string ->
  window_sec:float ->
  ?grace_sec:float ->
  unit ->
  (string * string * verdict) list
