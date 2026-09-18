(** Emptying a keeper's saved history ([masc_keeper_clear]).

    The clear saves the checkpoint of one trace with its conversation messages
    removed, and then says so in the keeper's turn-boundary store (RFC
    librarian-lifecycle §4.6). The order is the contract: the
    [History_cleared] line is appended only after the store reports the emptied
    checkpoint as saved, so a reader that sees the line knows the history was
    already emptied. A clear the store refused, or could not write, leaves no
    line.

    The line is not written first because a reader could then confirm its
    position against the still-full history with the line already in view,
    and have nothing left to explain the mismatch once the save lands. *)

type outcome =
  | Cleared of
      { cleared_message_count : int
      ; marker : (unit, string) result
            (** Whether the [History_cleared] line was written. On [Error] the
                history started over with no line to say why; running the
                clear again writes one. *)
      }
      (** The emptied checkpoint is the canonical one on disk. *)
  | Superseded of
      { incoming_turn_count : int
      ; known_turn_count : int
      }
      (** A newer writer owns the canonical checkpoint: the store's stale
          no-op. Nothing was written. *)
  | Not_saved of { detail : string }
      (** The save failed and no line was written. The store reports a save
          only once the payload, the rename and the directory fsync all
          succeeded, so a failure does not prove the checkpoint on disk is
          unchanged. *)

(** Empty the history [ctx] holds and save it as the checkpoint of [session].
    [preserve_system] keeps the [System] messages, which are not atoms, so
    either way the saved history holds no atom. The trace the line names is
    [session.session_id], the value the checkpoint is saved under.

    A failure to write the line is reported in [marker], never raised; only a
    cancellation escapes the append. *)
val clear
  :  keepers_dir:string
  -> runtime_id:string
  -> keeper_name:string
  -> session:Keeper_context_core.session_context
  -> preserve_system:bool
  -> Keeper_context_core.working_context
  -> outcome
