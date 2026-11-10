(** RFC-0240 §2.4 — close tool cycles left open by process death, at boot.

    Checkpoint persistence deliberately stores the in-flight tool cycle so
    recovery knows which calls were dispatched
    ({!Keeper_transcript_unit.partition}'s [protected_suffix]). Nothing closed
    it, so provider admission rejected the history on every reload and the
    lane stayed permanently unresumable.

    This runs during the [Recovering_persistence] boot phase, before keeper loops
    start, so no writer races the compare-and-swap. Shutdown hooks cannot cover
    this: an ungraceful kill runs none.

    A keeper's history is first read from its last message back to the last
    one that requests tool calls ({!Keeper_transcript_unit.read_tail_message}).
    A history whose last request has its results is left as it is. A history
    whose last request awaits results is read whole, and
    {!Keeper_transcript_unit.close_open_tail} of the whole history decides
    what is appended. For a history that parses the two readings agree, so
    nothing is appended to a history that the first reading leaves.

    A history whose last request has its results is not parsed here: the
    reading does not judge the messages it reads, reads none before the last
    request, does not read the header objects and does not check the chains.
    So nothing that is wrong with such a history is reported at boot,
    wherever it lies: a structural break, an object that is missing or does
    not match its digest among those not read, a chain that does not match.
    The keeper's next turn reads the whole history and meets it there. *)

type keeper_outcome =
  | Nothing_to_close
      (** No durable metadata, no canonical checkpoint yet, a canonical of a
          version this build supersedes, or a history whose last request has
          its results. It does not say that the history parses: such a
          history is not parsed here. *)
  | Closed of { tool_use_ids : string list }
  | Unparseable of Keeper_transcript_unit.structural_error
      (** Genuine corruption — only the open tail is recoverable. Reported
          for a history whose last request awaits results; no other history
          is parsed here. *)
  | Meta_unavailable of string
  | Checkpoint_unavailable of Keeper_checkpoint_store.Saved_history.ref_error
      (** The head or the end of the history could not be read, or the whole
          history of a keeper whose last request awaits results. *)
  | Commit_rejected of Keeper_checkpoint_store.checkpoint_cas_error

type report =
  { examined : int
  ; closed : int
  ; tool_results_appended : int
  ; unparseable : int
        (** Of the histories read whole, which are those whose last request
            awaits results. *)
  ; failed : int
        (** Metadata, load, and commit failures only. A load failure is of the
            head or the end of a history, or of a history read whole.
            [Unparseable] is counted separately: it is a correct refusal, not
            a recovery failure. *)
  ; outcomes : (string * keeper_outcome) list  (** In enumeration order. *)
  }

val recover_open_tails : Workspace.config -> report
(** Close every persisted keeper's open tool cycle. Each keeper is independent:
    a keeper whose recovery fails is reported in its outcome and the next
    keeper is read, because a single unrecoverable lane must not keep the rest
    of the fleet down. *)
