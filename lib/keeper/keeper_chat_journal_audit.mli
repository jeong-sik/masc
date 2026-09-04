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
[@@deriving show, eq]

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

(** IO shell: audit one operation. Reads the journal ([Journal_missing] /
    [Journal_corrupt] come from here), [Keeper_chat_store.load_all]s the
    store, joins rows by [turn_ref] and by the [Operation] delivery key
    derived from [operation_id], and compares. *)
val audit_operation :
  base_dir:string -> keeper_name:string -> operation_id:string -> verdict

(** Sweep every journal file under [<base>/.masc/keeper_chat_events/] modified
    in the last [window_sec] seconds (mtime), audit each, and return
    [(keeper, operation_id, verdict)] triples. Never raises except
    [Eio.Cancel.Cancelled]: per-file failures become [Journal_corrupt]
    verdicts. *)
val sweep :
  base_dir:string ->
  window_sec:float ->
  unit ->
  (string * string * verdict) list
