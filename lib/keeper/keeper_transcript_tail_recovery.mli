(** RFC-0240 §2.4 — close tool cycles left open by process death, at boot.

    Checkpoint persistence deliberately stores the in-flight tool cycle so
    recovery knows which calls were dispatched
    ({!Keeper_transcript_unit.partition}'s [protected_suffix]). Nothing closed
    it, so provider admission rejected the history on every reload and the
    lane stayed permanently unresumable.

    This runs during the [Recovering_requests] boot phase, before keeper loops
    start, so no writer races the compare-and-swap. Shutdown hooks cannot cover
    this: an ungraceful kill runs none. *)

type keeper_outcome =
  | Already_dispatchable
      (** No durable metadata, no canonical checkpoint yet, or no open tail. *)
  | Closed of { tool_use_ids : string list }
  | Unparseable of Keeper_transcript_unit.structural_error
      (** Genuine corruption — only the open tail is recoverable. *)
  | Meta_unavailable of string
  | Checkpoint_unavailable of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Commit_rejected of Keeper_checkpoint_store.checkpoint_cas_error

type report =
  { examined : int
  ; closed : int
  ; tool_results_appended : int
  ; unparseable : int
  ; failed : int
        (** Metadata, load, and commit failures only. [Unparseable] is counted
            separately: it is a correct refusal, not a recovery failure. *)
  ; outcomes : (string * keeper_outcome) list  (** In enumeration order. *)
  }

val recover_open_tails : Workspace.config -> report
(** Close every persisted keeper's open tool cycle. Each keeper is independent:
    one failure never aborts the sweep, because a single unrecoverable lane must
    not keep the rest of the fleet down. *)
